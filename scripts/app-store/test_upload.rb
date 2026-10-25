require 'minitest/autorun'
require 'tmpdir'
require_relative 'upload'

class AppStoreUploadTest < Minitest::Test
  def test_listing_limits_include_keyword_bytes
    metadata = JSON.parse(File.read(File.join(__dir__, 'metadata.example.json'))).reject { |key, _| %w[supportUrl marketingUrl privacyPolicyUrl].include?(key) }
    MuxAppStore.validate_copy(metadata)
    assert_raises(RuntimeError) { MuxAppStore.validate_copy(metadata.merge('keywords' => '界' * 34)) }
    assert_raises(RuntimeError) { MuxAppStore.validate_copy(metadata.merge('promotionalText' => 'x' * 171)) }
  end

  def test_placement_resolves_exact_dimensions_and_family_from_catalog
    asset = { 'file' => 'test.png', 'role' => 'screenshot', 'family' => 'iphone', 'width' => 1320, 'height' => 2868, 'size' => 100 }
    row = { 'attributes' => {
      'features' => [{ 'featureId' => 'APP_STORE_VERSIONS', 'placementPolicies' => [{ 'placementType' => 'APP_SCREENSHOT', 'groupLimits' => [{ 'groupIds' => %w[phone tablet], 'maxCount' => 10 }] }] }],
      'placementProfileGroups' => [{ 'placementProfileGroupId' => 'phone', 'displayClassId' => 'phone-display' }, { 'placementProfileGroupId' => 'tablet', 'displayClassId' => 'tablet-display' }],
      'displayClasses' => [{ 'displayClassId' => 'phone-display', 'deviceFamily' => 'IPHONE' }, { 'displayClassId' => 'tablet-display', 'deviceFamily' => 'IPAD' }],
      'imageSpecs' => [{ 'specId' => 'correct-size', 'dimensions' => { 'minWidth' => 1320, 'maxWidth' => 1320, 'minHeight' => 2868, 'maxHeight' => 2868 }, 'fileExtensions' => ['.png'], 'maxFileSize' => 500 }],
      'placementTypes' => [{ 'placementTypeId' => 'APP_SCREENSHOT', 'acceptsAssetCategories' => ['APP_SCREENSHOTS_AND_PREVIEWS'], 'specMappings' => [{ 'placementGroupId' => 'phone', 'specs' => ['correct-size'] }, { 'placementGroupId' => 'tablet', 'specs' => ['correct-size'] }] }]
    } }
    slots = MuxAppStore.placements_for(asset, [row])
    assert_equal ['phone'], slots.map { |s| s['group'] }
    assert_equal ['correct-size'], slots.first['specs']
    assert_raises(RuntimeError) { MuxAppStore.placements_for(asset.merge('width' => 100), [row]) }
    assert_raises(RuntimeError) { MuxAppStore.placements_for(asset.merge('role' => 'header'), [row]) }
  end

  class RecordingClient < MuxAppStore::Client
    attr_reader :requests
    def initialize; @requests = []; end
    private
    def transmit(uri, request)
      @requests << [uri, request]
      Struct.new(:code).new('200')
    end
  end

  def test_multipart_upload_uses_exact_ranges_without_api_token
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'image'); File.binwrite(path, 'abcdefgh')
      operations = [[4, 4], [0, 4]].map do |offset, length|
        { 'offset' => offset, 'length' => length, 'method' => 'PUT', 'url' => 'https://store-test.blobstore.apple.com/signed', 'requestHeaders' => [{ 'name' => 'Content-Type', 'value' => 'image/png' }] }
      end
      client = RecordingClient.new
      client.upload(path, operations)
      assert_equal %w[efgh abcd], client.requests.map { |_, request| request.body }
      assert client.requests.all? { |_, request| request['Authorization'].nil? }
      assert_raises(RuntimeError) { client.upload(path, [operations.first]) }
      assert_raises(RuntimeError) { client.upload(path, operations.map { |o| o.merge('url' => 'https://untrusted.example/upload') }) }
    end
  end

  def test_pagination_never_sends_credentials_to_an_external_host
    client = RecordingClient.new
    assert_raises(RuntimeError) { client.call('get', 'https://untrusted.example/next') }
    assert_empty client.requests
  end

  def test_opaque_png_validation
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'test.png')
      bytes = "\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR' + [1320, 2868].pack('NN') + [8, 2, 0, 0, 0].pack('C*') + "\0" * 4
      File.binwrite(path, bytes)
      assert_equal [1320, 2868], MuxAppStore.png_info(path)
      bytes.setbyte(25, 6); File.binwrite(path, bytes)
      assert_raises(RuntimeError) { MuxAppStore.png_info(path) }
    end
  end
end

class AppStorePublishFlowTest < Minitest::Test
  class FakeAPI
    attr_reader :images, :placements, :ordered
    def initialize(metadata)
      @metadata = metadata
      @images = {}; @placements = []; @ordered = []; @resources = {}
      @resources['/v1/appStoreVersionLocalizations/locale'] = { 'type' => 'appStoreVersionLocalizations', 'id' => 'locale', 'attributes' => { 'locale' => 'en-US', 'supportUrl' => 'https://example.com/support' } }
      @resources['/v1/appInfoLocalizations/info-locale'] = { 'type' => 'appInfoLocalizations', 'id' => 'info-locale', 'attributes' => { 'locale' => 'en-US', 'privacyPolicyUrl' => 'https://example.com/privacy' } }
    end
    def list(path)
      case path.split('?').first
      when '/v1/apps' then [{ 'id' => 'app', 'attributes' => { 'bundleId' => @metadata['bundleId'], 'name' => 'Mux Manager' } }]
      when '/v1/apps/app/appStoreVersions' then [{ 'id' => 'version', 'attributes' => { 'platform' => 'IOS', 'appVersionState' => 'PREPARE_FOR_SUBMISSION', 'versionString' => '0.1.0' } }]
      when '/v1/appStoreVersions/version/appStoreVersionLocalizations' then [@resources.fetch('/v1/appStoreVersionLocalizations/locale')]
      when '/v1/apps/app/appInfos' then [{ 'id' => 'info', 'attributes' => { 'state' => 'PREPARE_FOR_SUBMISSION' } }]
      when '/v1/appInfos/info/appInfoLocalizations' then [@resources.fetch('/v1/appInfoLocalizations/info-locale')]
      when '/v1/appAssetLibraryRefData' then [{ 'attributes' => {
        'features' => [{ 'featureId' => 'APP_STORE_VERSIONS', 'placementPolicies' => [{ 'placementType' => 'APP_SCREENSHOT', 'groupLimits' => [{ 'groupIds' => ['phone'], 'maxCount' => 10 }] }] }],
        'placementProfileGroups' => [{ 'placementProfileGroupId' => 'phone', 'displayClassId' => 'phone-display' }],
        'displayClasses' => [{ 'displayClassId' => 'phone-display', 'deviceFamily' => 'IPHONE' }],
        'imageSpecs' => [{ 'specId' => 'spec', 'dimensions' => { 'minWidth' => 1320, 'maxWidth' => 1320, 'minHeight' => 2868, 'maxHeight' => 2868 }, 'fileExtensions' => ['.png'], 'maxFileSize' => 500 }],
        'placementTypes' => [{ 'placementTypeId' => 'APP_SCREENSHOT', 'acceptsAssetCategories' => ['APP_SCREENSHOTS_AND_PREVIEWS'], 'specMappings' => [{ 'placementGroupId' => 'phone', 'specs' => ['spec'] }] }]
      } }]
      when '/v1/appStoreVersionLocalizations/locale/placements' then JSON.parse(JSON.generate(@placements))
      else raise "Unexpected list: #{path}"
      end
    end
    def call(method, path, body = nil)
      data = body && JSON.parse(JSON.generate(body))['data']
      if method == 'get'
        resource = if path == '/v1/apps/app/assetLibrary'
                     { 'id' => 'library' }
                   elsif path.start_with?('/v1/appAssetLibraryImages/')
                     @images.fetch(path.split('/').last)
                   else
                     @resources.fetch(path)
                   end
        return { 'data' => resource }
      end
      if method == 'patch'
        resource = path.start_with?('/v1/appAssetLibraryImages/') ? @images.fetch(path.split('/').last) : @resources.fetch(path)
        resource['attributes'].merge!(data['attributes'])
        if data.dig('attributes', 'uploaded')
          resource['attributes']['state'] = 'PREPARE_FOR_SUBMISSION'
          resource['attributes']['specId'] = 'spec'
        end
        return { 'data' => resource }
      end
      raise "Unexpected mutation method: #{method}" unless method == 'post'
      case path
      when '/v1/appAssetLibraryImages'
        id = "image-#{@images.length}"
        data['id'] = id; data['attributes']['state'] = 'AWAITING_UPLOAD'; data['attributes']['uploadOperations'] = []
        @images[id] = data
      when '/v1/appAssetLibraryPlacements'
        data['id'] = "placement-#{@placements.length}"; @placements << data
      when '/v1/appAssetLibraryPlacementOrderingRequests'
        @ordered = data.fetch('relationships').fetch('orderedPlacements').fetch('data').map { |d| d['id'] }
        data['id'] = 'order'
      else raise "Unexpected POST (including review/release): #{path}"
      end
      { 'data' => data }
    end
    def upload(path, _operations)
      raise 'Missing staged bytes' unless File.size(path).positive?
    end
    def support_url; @resources['/v1/appStoreVersionLocalizations/locale']['attributes']['supportUrl']; end
    def privacy_url; @resources['/v1/appInfoLocalizations/info-locale']['attributes']['privacyPolicyUrl']; end
  end

  def test_requested_support_and_privacy_urls_are_updated
    metadata = JSON.parse(File.read(File.join(__dir__, 'metadata.example.json')))
    Dir.mktmpdir do |output|
      api = FakeAPI.new(metadata)
      publisher = MuxAppStore::Publisher.new(api, output, metadata)
      publisher.discover
      publisher.update_metadata
      assert_equal metadata.fetch('supportUrl'), api.support_url
      assert_equal metadata.fetch('privacyPolicyUrl'), api.privacy_url
    end
  end

  def test_upload_verifies_preserves_unrelated_metadata_and_reruns_without_duplicates
    metadata = JSON.parse(File.read(File.join(__dir__, 'metadata.example.json'))).reject { |key, _| %w[supportUrl marketingUrl privacyPolicyUrl].include?(key) }
    Dir.mktmpdir do |output|
      assets = %w[first second].map do |name|
        path = File.join(output, name); File.write(path, name)
        { 'file' => name, 'role' => 'screenshot', 'family' => 'iphone', 'width' => 1320, 'height' => 2868,
          'size' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      api = FakeAPI.new(metadata)
      2.times do
        publisher = MuxAppStore::Publisher.new(api, output, metadata)
        publisher.discover
        publisher.publish(assets)
      end
      assert_equal 2, api.images.length
      assert_equal 2, api.placements.length
      assert_equal %w[placement-0 placement-1], api.ordered
      assert_equal 'https://example.com/support', api.support_url
      assert_equal 'https://example.com/privacy', api.privacy_url
      verification = JSON.parse(File.read(File.join(output, 'upload-verification.json')))
      assert verification['metadataVerified']
      assert_equal %w[placement-0 placement-1], verification['placementIds']
    end
  end
end

class AppStoreMixedMediaOrderingTest < Minitest::Test
  class API < AppStorePublishFlowTest::FakeAPI
    def list(path)
      result = super
      if path.start_with?('/v1/appAssetLibraryRefData')
        attributes = result.first['attributes']
        spec = attributes['imageSpecs'].first.merge('specId' => 'preview-spec', 'fileExtensions' => ['.mp4'],
          'dimensions' => { 'minWidth' => 886, 'maxWidth' => 886, 'minHeight' => 1920, 'maxHeight' => 1920 })
        attributes['videoSpecs'] = [spec]
        attributes['features'].first['placementPolicies'] << { 'placementType' => 'APP_PREVIEW', 'groupLimits' => [{ 'groupIds' => ['phone'], 'maxCount' => 3 }] }
        attributes['placementTypes'] << { 'placementTypeId' => 'APP_PREVIEW', 'acceptsAssetCategories' => ['APP_SCREENSHOTS_AND_PREVIEWS'],
          'specMappings' => [{ 'placementGroupId' => 'phone', 'specs' => ['preview-spec'] }] }
      end
      result
    end
    def call(method, path, body = nil)
      if path.include?('/appAssetLibraryVideos')
        response = super(method, path.sub('/appAssetLibraryVideos', '/appAssetLibraryImages'), body)
        response['data']['attributes']['specId'] = 'preview-spec' if response['data'].dig('attributes', 'uploaded')
        return response
      end
      if path == '/v1/appAssetLibraryPlacementOrderingRequests'
        ids = JSON.parse(JSON.generate(body)).dig('data', 'relationships', 'orderedPlacements', 'data').map { |p| p['id'] }
        types = placements.select { |p| ids.include?(p['id']) }.map { |p| p.dig('attributes', 'placementType') }.uniq
        raise 'Apple rejects mixed placement types in one ordering request' unless types.length == 1
      end
      super
    end
  end
  def test_screenshots_and_previews_sharing_a_device_group_are_ordered_separately
    metadata = JSON.parse(File.read(File.join(__dir__, 'metadata.example.json'))).reject { |key, _| %w[supportUrl marketingUrl privacyPolicyUrl].include?(key) }
    Dir.mktmpdir do |output|
      assets = %w[first second preview].each_with_index.map do |name, index|
        path = File.join(output, name); File.write(path, name)
        { 'file' => name, 'role' => index == 2 ? 'preview' : 'screenshot', 'family' => 'iphone',
          'width' => index == 2 ? 886 : 1320, 'height' => index == 2 ? 1920 : 2868,
          'size' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      api = API.new(metadata)
      publisher = MuxAppStore::Publisher.new(api, output, metadata)
      publisher.discover; publisher.publish(assets)
      assert_equal 3, api.placements.length
      assert_equal %w[placement-0 placement-1], api.ordered
      assert_equal %w[APP_SCREENSHOT APP_SCREENSHOT APP_PREVIEW], api.placements.map { |p| p.dig('attributes', 'placementType') }
    end
  end
end
