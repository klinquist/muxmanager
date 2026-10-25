#!/usr/bin/env ruby
# Ruby standard library only. Credentials stay on disk; JWTs stay in memory.
require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'optparse'
require 'uri'
require 'fileutils'
require 'time'
require 'open3'
require 'tempfile'

module MuxAppStore
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = File.join(ROOT, 'output/app-store/2026-10')
  EDITABLE = %w[PREPARE_FOR_SUBMISSION INVALID_BINARY REJECTED METADATA_REJECTED DEVELOPER_REJECTED].freeze

  def self.payload(type, attributes: {}, relationships: {}, id: nil)
    data = { type: type, attributes: attributes }
    data[:id] = id if id
    data[:relationships] = relationships unless relationships.empty?
    { data: data }
  end

  def self.relation(type, id)
    { data: { type: type, id: id } }
  end

  def self.png_info(path)
    bytes = File.binread(path, 33)
    raise "Invalid PNG: #{path}" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b) && bytes.bytesize >= 33 && bytes[12, 4] == 'IHDR'
    width, height = bytes[16, 8].unpack('NN')
    raise "PNG must be opaque RGB/grayscale: #{path}" unless [0, 2].include?(bytes.getbyte(25))
    [width, height]
  end

  def self.validate_copy(metadata)
    { 'name' => 30, 'subtitle' => 30, 'promotionalText' => 170, 'description' => 4000 }.each do |field, limit|
      value = metadata.fetch(field)
      raise "#{field} is empty or exceeds #{limit} characters" if value.empty? || value.length > limit
    end
    raise 'Keywords exceed 100 UTF-8 bytes' if metadata.fetch('keywords').bytesize > 100
    raise 'Unexpected bundle ID' unless metadata.fetch('bundleId') == 'com.linquist.muxmanager'
  end

  def self.video_info(path)
    sidecar = path.sub(/\.mp4\z/, '.json')
    info = JSON.parse(File.read(sidecar))
    raise 'Preview metadata does not match its file' unless info.fetch('sha256') == Digest::SHA256.file(path).hexdigest
    raise 'Preview must be 15–30 seconds of H.264 at 30 fps' unless info['videoCodec'] == 'h264' && info.fetch('duration').between?(15, 30) && (info.fetch('fps') - 30).abs < 0.01
    raise 'Preview needs stereo AAC at 44.1/48 kHz' unless info['audioCodec'] == 'aac' && info['channels'] == 2 && [44100, 48000].include?(info['sampleRate'])
    info.slice('width', 'height', 'duration', 'fps')
  end

  def self.assets(output = OUTPUT, creative_only: false)
    scenes = JSON.parse(File.read(File.join(output, 'scenes.json')))
    files = []
    %w[iphone ipad].each do |family|
      next if creative_only
      scenes.each_with_index do |scene, index|
        files << { 'file' => "screenshots/#{family}-#{index + 1}-#{scene['id']}.png", 'role' => 'screenshot', 'family' => family }
      end
    end
    unless creative_only
      %w[iphone ipad].each do |family|
        file = "previews/#{family}-preview.mp4"
        files << { 'file' => file, 'role' => 'preview', 'family' => family } if File.file?(File.join(output, file))
      end
    end
    files << { 'file' => 'artwork/header-3840x1646.png' , 'role' => 'header' }
    files << { 'file' => 'artwork/search-1920x1280.png', 'role' => 'search' }
    files.each do |asset|
      path = File.join(output, asset['file'])
      raise "Missing asset: #{asset['file']}. Run capture.py and render.swift first." unless File.file?(path)
      if asset['role'] == 'preview'
        asset.merge!(video_info(path))
      else
        asset['width'], asset['height'] = png_info(path)
      end
      expected = case asset['role']
                 when 'header' then [3840, 1646]
                 when 'search' then [1920, 1280]
                 when 'preview' then asset['family'] == 'iphone' ? [886, 1920] : [1200, 1600]
                 else asset['family'] == 'iphone' ? [1320, 2868] : [2064, 2752]
                 end
      raise "Wrong dimensions: #{asset['file']}" unless expected == [asset['width'], asset['height']]
      asset['sha256'] = Digest::SHA256.file(path).hexdigest
      asset['size'] = File.size(path)
    end
    # Require real capture provenance for every screenshot, not generated UI.
    capture = creative_only ? [] : JSON.parse(File.read(File.join(output, 'capture-manifest.json')))
    files.select { |a| a['role'] == 'screenshot' }.each do |asset|
      scene = scenes.find { |s| asset['file'].end_with?("-#{s['id']}.png") }
      raise "No native capture provenance: #{asset['file']}" unless capture.any? { |c| c['family'] == asset['family'] && c['scene'] == scene['id'] }
    end
    files
  end

  # Resolve 2026 placement IDs from Apple's reference catalog, not guessed enums.
  def self.placements_for(asset, rows)
    catalog = rows.map { |row| row.fetch('attributes') }
    groups = catalog.flat_map { |a| a.fetch('placementProfileGroups', []) }
    displays = catalog.flat_map { |a| a.fetch('displayClasses', []) }
    specs = catalog.flat_map { |a| a.fetch(asset['role'] == 'preview' ? 'videoSpecs' : 'imageSpecs', []) }
    policies = catalog.flat_map { |a| a.fetch('features', []) }.select { |f| f['featureId'] == 'APP_STORE_VERSIONS' }.flat_map { |f| f.fetch('placementPolicies', []) }
    valid = specs.select do |spec|
      d = spec.fetch('dimensions')
      asset['width'].between?(d.fetch('minWidth'), d.fetch('maxWidth')) &&
        asset['height'].between?(d.fetch('minHeight'), d.fetch('maxHeight')) &&
        spec.fetch('fileExtensions', []).include?(asset['role'] == 'preview' ? '.mp4' : '.png') && asset['size'] <= spec.fetch('maxFileSize')
    end.map { |s| s.fetch('specId') }
    result = []
    catalog.flat_map { |a| a.fetch('placementTypes', []) }.each do |type|
      id = type.fetch('placementTypeId')
      match = case asset['role']
              when 'screenshot' then id == 'APP_SCREENSHOT'
              when 'preview' then id == 'APP_PREVIEW'
              when 'header' then id.include?('PRODUCT_PAGE_HEADER')
              when 'search' then id.include?('SEARCH') && id.include?('ASSET')
              end
      next unless match
      category = %w[screenshot preview].include?(asset['role']) ? 'APP_SCREENSHOTS_AND_PREVIEWS' : 'CREATIVE_ASSETS'
      next unless type.fetch('acceptsAssetCategories', []).include?(category)
      type.fetch('specMappings', []).each do |mapping|
        compatible = mapping.fetch('specs') & valid
        next if compatible.empty?
        group_id = mapping.fetch('placementGroupId')
        group = groups.find { |g| g['placementProfileGroupId'] == group_id }
        next unless group
        display = displays.find { |d| d['displayClassId'] == group['displayClassId'] }
        family = display && display['deviceFamily']
        if asset['family']
          next unless family == asset['family'].upcase
        else
          next if family && !%w[IPHONE IPAD].include?(family)
        end
        policy = policies.find { |p| p['placementType'] == id }
        limit = policy && policy.fetch('groupLimits', []).find { |l| l.fetch('groupIds').include?(group_id) }
        next unless limit
        result << { 'type' => id, 'group' => group_id, 'specs' => compatible, 'maxCount' => limit.fetch('maxCount') }
      end
    end
    result = result.uniq { |p| [p['type'], p['group']] }
    raise "Apple's reference data has no compatible placement for #{asset['file']}" if result.empty?
    result
  end

  class Client
    BASE = 'https://api.appstoreconnect.apple.com'
    def initialize
      @key_id = ENV.fetch('ASC_KEY_ID')
      @issuer = ENV.fetch('ASC_ISSUER_ID')
      path = ENV.fetch('ASC_KEY_PATH', File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{@key_id}.p8"))
      @key = OpenSSL::PKey.read(File.read(path))
    end

    def token
      now = Time.now.to_i
      return @token if @token && now < @expires - 30
      @expires = now + 600
      encode = ->(v) { Base64.urlsafe_encode64(JSON.generate(v), padding: false) }
      data = [encode.call(alg: 'ES256', kid: @key_id, typ: 'JWT'),
              encode.call(iss: @issuer, iat: now, exp: @expires, aud: 'appstoreconnect-v1')].join('.')
      signature = OpenSSL::ASN1.decode(@key.sign('sha256', data)).value.map { |n| n.value.to_i.to_s(16).rjust(64, '0') }.join
      @token = "#{data}.#{Base64.urlsafe_encode64([signature].pack('H*'), padding: false)}"
    end

    def call(method, path, body = nil)
      uri = URI(path.start_with?('https://') ? path : BASE + path)
      raise 'Refusing to send credentials to a non-ASC host' unless uri.scheme == 'https' && uri.host == 'api.appstoreconnect.apple.com' && uri.port == 443
      request = Net::HTTP.const_get(method.capitalize).new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body) if body
      response = transmit(uri, request)
      unless response.code.to_i.between?(200, 299)
        errors = JSON.parse(response.body).fetch('errors', []).map { |e| [e['code'], e['detail']].compact.join(': ') }.join('; ') rescue 'Unparseable API response'
        raise "ASC #{method.upcase} #{uri.path}: HTTP #{response.code}: #{errors}"
      end
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    end

    def list(path)
      rows = []
      while path
        response = call('get', path)
        rows.concat(response.fetch('data'))
        path = response.dig('links', 'next')
      end
      rows
    end

    def upload(path, operations)
      size = File.size(path)
      ranges = operations.map { |o| [o.fetch('offset'), o.fetch('length')] }.sort
      ending = 0
      ranges.each do |offset, length|
        raise 'Invalid or incomplete upload byte ranges' unless offset == ending && length.positive? && offset + length <= size
        ending += length
      end
      raise 'Upload operations do not cover the whole file' unless ending == size
      File.open(path, 'rb') do |file|
        operations.each do |operation|
          uri = URI(operation.fetch('url'))
          raise 'Non-Apple upload destination' unless uri.scheme == 'https' && uri.host.end_with?('.apple.com') && uri.port == 443
          file.seek(operation.fetch('offset'))
          bytes = file.read(operation.fetch('length'))
          request = Net::HTTP.const_get(operation.fetch('method').capitalize).new(uri)
          operation.fetch('requestHeaders').each do |header|
            raise 'Unexpected auth header in upload instructions' if header.fetch('name').casecmp('Authorization').zero?
            request[header.fetch('name')] = header.fetch('value')
          end
          # Signed upload URLs need only Apple's supplied headers, never our JWT.
          request.body = bytes
          response = transmit(uri, request)
          raise "Asset byte upload failed: HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
        end
      end
    end

    private

    def transmit(uri, request)
      # Match the user's existing release workflow. Curl is also available where
      # the embedded Ruby resolver cannot reach the network. Headers and signed
      # URLs are passed over stdin, never as command-line arguments.
      config = ["url = #{JSON.generate(uri.to_s)}", "request = #{JSON.generate(request.method)}"]
      request.each_header { |name, value| config << "header = #{JSON.generate("#{name}: #{value}")}" }
      temporary = nil
      if request.body
        temporary = Tempfile.new('mux-asc-request')
        temporary.binmode; temporary.write(request.body); temporary.flush
        config << "data-binary = #{JSON.generate('@' + temporary.path)}"
      end
      if ENV['MUX_ASC_BRIDGE']
        # Restricted agent sessions can execute approved curl commands directly
        # through their command tool. The private file bridge keeps tokens and
        # signed URLs out of tool arguments and outputs.
        directory = File.expand_path(ENV.fetch('MUX_ASC_BRIDGE'))
        FileUtils.mkdir_p(directory, mode: 0700)
        @bridge_sequence = (@bridge_sequence || 0) + 1
        id = format('%04d', @bridge_sequence)
        File.write(File.join(directory, "#{id}.conf"), config.join("\n") + "\n", mode: 'w', perm: 0600)
        ready = File.join(directory, 'ready.json')
        File.write(ready + '.tmp', JSON.generate(id: id), mode: 'w', perm: 0600)
        File.rename(ready + '.tmp', ready)
        answer = File.join(directory, "#{id}.response.json")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
        until File.file?(answer)
          raise 'Timed out waiting for the command-tool curl bridge' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
        end
        response = JSON.parse(File.read(answer))
        code = response.fetch('code')
        raise 'Command-tool curl transport failed' unless code.match?(/\A[1-5]\d\d\z/)
        return Struct.new(:code, :body).new(code, File.binread(File.join(directory, "#{id}.body")))
      end
      output, _error, status = Open3.capture3('curl', '-s', '-S', '--compressed', '--connect-timeout', '20', '--max-time', '120',
        '--config', '-', '--write-out', "\n%{http_code}", stdin_data: config.join("\n") + "\n")
      raise "Curl transport failed (exit #{status.exitstatus}) contacting #{uri.host}" unless status.success?
      body, _, code = output.rpartition("\n")
      raise 'Missing HTTP status from curl' unless code.match?(/\A\d{3}\z/)
      Struct.new(:code, :body).new(code, body)
    ensure
      temporary&.close!
      File.delete(File.join(directory, "#{id}.conf")) if directory && id && File.file?(File.join(directory, "#{id}.conf"))
    end
  end

  class Publisher
    def initialize(client, output, metadata)
      @client = client; @output = output; @metadata = metadata
      @state_path = File.join(output, 'upload-state.json')
      @state = File.file?(@state_path) ? JSON.parse(File.read(@state_path)) : { 'assets' => {}, 'placements' => {} }
    end

    def discover
      query = URI.encode_www_form('filter[bundleId]' => @metadata.fetch('bundleId'))
      apps = @client.list("/v1/apps?#{query}")
      raise 'Expected exactly one matching app' unless apps.length == 1 && apps.first.dig('attributes', 'bundleId') == @metadata['bundleId']
      @app = apps.first
      versions = @client.list("/v1/apps/#{@app['id']}/appStoreVersions")
      editable = versions.select { |v| v.dig('attributes', 'platform') == 'IOS' && EDITABLE.include?(v.dig('attributes', 'appVersionState') || v.dig('attributes', 'appStoreState')) }
      if ENV['ASC_VERSION']
        editable.select! { |v| v.dig('attributes', 'versionString') == ENV['ASC_VERSION'] }
      end
      raise 'Expected one editable iOS version. Set ASC_VERSION if more than one exists.' unless editable.length == 1
      @version = editable.first
      localizations = @client.list("/v1/appStoreVersions/#{@version['id']}/appStoreVersionLocalizations")
      @localization = localizations.find { |l| l.dig('attributes', 'locale') == @metadata['locale'] }
      infos = @client.list("/v1/apps/#{@app['id']}/appInfos")
      @info = infos.find { |i| EDITABLE.include?(i.dig('attributes', 'state') || i.dig('attributes', 'appStoreState')) }
      raise 'No editable app information record' unless @info
      @info_localization = @client.list("/v1/appInfos/#{@info['id']}/appInfoLocalizations").find { |l| l.dig('attributes', 'locale') == @metadata['locale'] }
      @library = @client.call('get', "/v1/apps/#{@app['id']}/assetLibrary").fetch('data')
      @reference = @client.list('/v1/appAssetLibraryRefData?filter%5Bfeatures%5D=APP_STORE_VERSIONS')
      # Metadata backup excludes credential-bearing upload operations/URLs.
      snapshot = { 'app' => @app, 'version' => @version, 'localization' => @localization, 'appInfoLocalization' => @info_localization, 'reference' => @reference }
      File.write(File.join(@output, 'api-inspection.json'), JSON.pretty_generate(snapshot) + "\n")
      puts "Found #{@app.dig('attributes', 'name')}, iOS #{@version.dig('attributes', 'versionString')}, #{@metadata['locale']}"
      snapshot
    end

    def publish(files)
      plan = files.map { |asset| [asset, MuxAppStore.placements_for(asset, @reference)] }
      # Resolve and validate every placement before the first mutation.
      counts = Hash.new(0)
      plan.each { |_, slots| slots.each { |s| counts[[s['type'], s['group']]] += 1; raise 'Too many assets for an Apple placement group' if counts[[s['type'], s['group']]] > s['maxCount'] } }
      if @state['app'] && @state['app'] != @app['id']
        raise 'Saved upload state belongs to a different app'
      end
      @state['app'] = @app['id']; @state['version'] = @version['id']; save_state
      # Stage and verify all media before changing the product page metadata.
      staged = plan.map { |asset, slots| [asset, slots, stage(asset)] }
      existing = @client.list("/v1/appStoreVersionLocalizations/#{@localization['id']}/placements?sort=placementGroupPosition&include=image,video")
      needed = Hash.new(0)
      staged.each do |asset, slots, image|
        slots.each do |slot|
          raise "Processed specification mismatch for #{asset['file']}" unless slot['specs'].include?(image.dig('attributes', 'specId'))
          same = existing.any? { |p| p.dig('attributes', 'placementType') == slot['type'] && p.dig('attributes', 'placementGroup') == slot['group'] && p.dig('relationships', asset['role'] == 'preview' ? 'video' : 'image', 'data', 'id') == image['id'] }
          needed[[slot['type'], slot['group']]] += 1 unless same
          occupied = existing.count { |p| p.dig('attributes', 'placementType') == slot['type'] && p.dig('attributes', 'placementGroup') == slot['group'] }
          raise "Existing content fills #{slot['group']}; no content was deleted" if occupied + needed[[slot['type'], slot['group']]] > slot['maxCount']
        end
      end
      update_metadata
      order = Hash.new { |h, k| h[k] = [] }
      staged.each do |asset, slots, image|
        slots.each do |slot|
          raise "Processed specification mismatch for #{asset['file']}" unless slot['specs'].include?(image.dig('attributes', 'specId'))
          match = existing.find do |p|
            p.dig('attributes', 'placementType') == slot['type'] && p.dig('attributes', 'placementGroup') == slot['group'] && p.dig('relationships', asset['role'] == 'preview' ? 'video' : 'image', 'data', 'id') == image['id']
          end
          if match.nil?
            in_group = existing.count { |p| p.dig('attributes', 'placementType') == slot['type'] && p.dig('attributes', 'placementGroup') == slot['group'] }
            raise "Existing content fills #{slot['group']}; no content was deleted" if in_group >= slot['maxCount']
            body = MuxAppStore.payload('appAssetLibraryPlacements', attributes: { placementType: slot['type'], placementGroup: slot['group'] },
              relationships: { (asset['role'] == 'preview' ? :video : :image) => MuxAppStore.relation(asset['role'] == 'preview' ? 'appAssetLibraryVideos' : 'appAssetLibraryImages', image['id']), appStoreVersionLocalization: MuxAppStore.relation('appStoreVersionLocalizations', @localization['id']) })
            match = @client.call('post', '/v1/appAssetLibraryPlacements', body).fetch('data')
            existing << match
          end
          key = [asset['sha256'], slot['type'], slot['group'], @localization['id']].join(':')
          @state['placements'][key] = match['id']; save_state
          order[[slot['group'], slot['type']]] << match['id']
        end
      end
      order.each do |(group, placement_type), ids|
        next unless %w[APP_SCREENSHOT APP_PREVIEW].include?(placement_type)
        next if ids.length == 1
        # Include any unrelated placements so ordering does not remove their slots.
        extra = existing.select { |p| p.dig('attributes', 'placementGroup') == group && p.dig('attributes', 'placementType') == placement_type }.map { |p| p['id'] } - ids
        @client.call('post', '/v1/appAssetLibraryPlacementOrderingRequests', MuxAppStore.payload('appAssetLibraryPlacementOrderingRequests',
          attributes: { placementGroup: group }, relationships: {
            orderedPlacements: { data: (ids + extra).map { |id| { type: 'appAssetLibraryPlacements', id: id } } },
            appStoreVersionLocalization: MuxAppStore.relation('appStoreVersionLocalizations', @localization['id']) }))
      end
      verify_metadata
      verify = @client.list("/v1/appStoreVersionLocalizations/#{@localization['id']}/placements?sort=placementGroupPosition&include=image,video")
      expected = order.values.flatten
      raise 'Placement verification failed' unless (expected - verify.map { |p| p['id'] }).empty?
      File.write(File.join(@output, 'upload-verification.json'), JSON.pretty_generate({ 'verifiedAt' => Time.now.utc.iso8601, 'appId' => @app['id'], 'versionId' => @version['id'], 'placementIds' => expected, 'metadataVerified' => true }) + "\n")
      puts 'Uploaded and verified metadata and placements. The version has not been submitted for review or released.'
    end

    def update_metadata
      version_attributes = @metadata.slice('description', 'promotionalText', 'keywords', 'supportUrl', 'marketingUrl')
      @localization = upsert('appStoreVersionLocalizations', @localization, version_attributes, 'appStoreVersion', 'appStoreVersions', @version['id'])
      info_attributes = @metadata.slice('name', 'subtitle', 'privacyPolicyUrl')
      @info_localization = upsert('appInfoLocalizations', @info_localization, info_attributes, 'appInfo', 'appInfos', @info['id'])
      verify_metadata
      File.write(File.join(@output, 'metadata-verification.json'), JSON.pretty_generate({
        'verifiedAt' => Time.now.utc.iso8601, 'appId' => @app['id'], 'versionId' => @version['id'],
        'locale' => @metadata['locale'], 'metadataSha256' => Digest::SHA256.hexdigest(JSON.generate(@metadata))
      }) + "\n")
      puts 'Metadata updated and verified.'
    end

    private

    def upsert(type, resource, attributes, parent, parent_type, parent_id)
      if resource
        @client.call('patch', "/v1/#{type}/#{resource['id']}", MuxAppStore.payload(type, id: resource['id'], attributes: attributes)).fetch('data')
      else
        @client.call('post', "/v1/#{type}", MuxAppStore.payload(type, attributes: attributes.merge('locale' => @metadata['locale']),
          relationships: { parent => MuxAppStore.relation(parent_type, parent_id) })).fetch('data')
      end
    end

    def verify_metadata
      [[@localization, %w[description promotionalText keywords supportUrl marketingUrl]], [@info_localization, %w[name subtitle privacyPolicyUrl]]].each do |resource, fields|
        current = @client.call('get', "/v1/#{resource['type']}/#{resource['id']}").fetch('data')
        fields.select { |f| @metadata.key?(f) }.each { |f| raise "Metadata verification failed: #{f}" unless current.dig('attributes', f) == @metadata[f] }
      end
    end

    def stage(asset)
      type = asset['role'] == 'preview' ? 'appAssetLibraryVideos' : 'appAssetLibraryImages'
      resource = @state['assets'][asset['sha256']]
      if resource
        image = @client.call('get', "/v1/#{type}/#{resource}").fetch('data')
        state = image.dig('attributes', 'state')
        return poll_image(image['id'], type) unless %w[AWAITING_UPLOAD FAILED].include?(state)
        raise "Previous asset #{asset['file']} is #{state}. Inspect its library record before retrying."
      end
      category = %w[screenshot preview].include?(asset['role']) ? 'APP_SCREENSHOTS_AND_PREVIEWS' : 'CREATIVE_ASSETS'
      attributes = {
        fileName: File.basename(asset['file']), fileSize: asset['size'], category: category,
        referenceName: "Mux Manager #{asset['file']} #{asset['sha256'][0, 12]}"
      }
      attributes[:previewFrameTimeCode] = '00:00:02:00' if asset['role'] == 'preview'
      body = MuxAppStore.payload(type, attributes: attributes, relationships: { assetLibrary: MuxAppStore.relation('appAssetLibraries', @library['id']) })
      image = @client.call('post', "/v1/#{type}", body).fetch('data')
      @state['assets'][asset['sha256']] = image['id']; save_state
      @client.upload(File.join(@output, asset['file']), image.fetch('attributes').fetch('uploadOperations'))
      @client.call('patch', "/v1/#{type}/#{image['id']}", MuxAppStore.payload(type, id: image['id'], attributes: { uploaded: true }))
      puts "Uploaded bytes: #{asset['file']}"
      poll_image(image['id'], type)
    end

    def poll_image(id, type = 'appAssetLibraryImages')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      loop do
        image = @client.call('get', "/v1/#{type}/#{id}").fetch('data')
        state = image.dig('attributes', 'state')
        return image if %w[PREPARE_FOR_SUBMISSION APPROVED].include?(state)
        raise "Asset processing failed: #{image.dig('attributes', 'stateDetails')}" if state == 'FAILED'
        raise "Asset #{id} is still #{state}. Rerun later to resume." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 3
      end
    end

    def save_state
      temporary = @state_path + '.tmp'
      File.write(temporary, JSON.pretty_generate(@state) + "\n")
      File.rename(temporary, @state_path)
    end
  end

  def self.main
    require 'time'
    options = { mode: :inspect, output: OUTPUT }
    OptionParser.new do |p|
      p.banner = 'Usage: ruby scripts/app-store/upload.rb [--validate | --inspect | --upload] [--metadata-only]'
      p.on('--validate', 'Offline validation; no credentials or network') { options[:mode] = :validate }
      p.on('--inspect', 'Read-only API discovery (default)') { options[:mode] = :inspect }
      p.on('--upload', 'Upload and verify the prepared assets and listing') { options[:mode] = :upload }
      p.on('--metadata-only', 'Validate/update copy without requiring screenshots') { options[:metadata_only] = true }
      p.on('--creative-only', 'Upload copy and header/search artwork without screenshots') { options[:creative_only] = true }
      p.on('--output DIRECTORY') { |v| options[:output] = File.expand_path(v) }
    end.parse!
    output = options[:output]
    metadata = JSON.parse(File.read(File.join(output, 'metadata.json')))
    validate_copy(metadata)
    files = options[:metadata_only] || options[:mode] == :inspect ? [] : assets(output, creative_only: options[:creative_only])
    if options[:mode] == :validate
      puts "Validated listing#{options[:metadata_only] ? '' : " and #{files.length} validated media assets"}."
      return
    end
    publisher = Publisher.new(Client.new, output, metadata)
    publisher.discover
    if options[:mode] == :upload
      options[:metadata_only] ? publisher.update_metadata : publisher.publish(files)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    MuxAppStore.main
  rescue StandardError => e
    warn "App Store operation stopped: #{e.message}"
    exit 1
  end
end
