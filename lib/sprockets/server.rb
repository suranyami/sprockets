require 'rack/request'
require 'time'

module Sprockets
  # `Server` is a concern mixed into `Environment` and
  # `Index` that provides a Rack compatible `call`
  # interface and url generation helpers.
  module Server
    # `call` implements the Rack 1.x specification which accepts an
    # `env` Hash and returns a three item tuple with the status code,
    # headers, and body.
    #
    # Mapping your environment at a url prefix will serve all assets
    # in the path.
    #
    #     map "/assets" do
    #       run Sprockets::Environment.new
    #     end
    #
    # A request for `"/assets/foo/bar.js"` will search your
    # environment for `"foo/bar.js"`.
    def call(env)
      start_time = Time.now.to_f
      time_elapsed = lambda { ((Time.now.to_f - start_time) * 1000).to_i }

      msg = "Served asset #{env['PATH_INFO']} -"

      # URLs containing a `".."` are rejected for security reasons.
      if forbidden_request?(env)
        return forbidden_response
      end

      # Mark session as "skipped" so no `Set-Cookie` header is set
      env['rack.session.options'] ||= {}
      env['rack.session.options'][:defer] = true
      env['rack.session.options'][:skip] = true

      # Extract the path from everything after the leading slash
      path = env['PATH_INFO'].to_s.sub(/^\//, '')

      # Look up the asset.
      asset = find_asset(path)
      asset.to_a if asset

      # `find_asset` returns nil if the asset doesn't exist
      if asset.nil?
        logger.info "#{msg} 404 Not Found (#{time_elapsed.call}ms)"

        # Return a 404 Not Found
        not_found_response

      # Check request headers `HTTP_IF_MODIFIED_SINCE` and
      # `HTTP_IF_NONE_MATCH` against the assets mtime and digest
      elsif not_modified?(asset, env) || etag_match?(asset, env)
        logger.info "#{msg} 304 Not Modified (#{time_elapsed.call}ms)"

        # Return a 304 Not Modified
        not_modified_response(asset, env)

      else
        logger.info "#{msg} 200 OK (#{time_elapsed.call}ms)"

        # Return a 200 with the asset contents
        ok_response(asset, env)
      end
    rescue Exception => e
      logger.error "Error compiling asset #{path}:"
      logger.error "#{e.class.name}: #{e.message}"

      case content_type_of(path)
      when "application/javascript"
        # Re-throw JavaScript asset exceptions to the browser
        logger.info "#{msg} 500 Internal Server Error\n\n"
        return javascript_exception_response(e)
      when "text/css"
        # Display CSS asset exceptions in the browser
        logger.info "#{msg} 500 Internal Server Error\n\n"
        return css_exception_response(e)
      else
        raise
      end
    end

    # Deprecated: `path` is a url helper that looks up an asset given a
    # `logical_path` and returns a path String. By default, the
    # asset's digest fingerprint is spliced into the filename.
    #
    #     /assets/application-3676d55f84497cbeadfc614c1b1b62fc.js
    #
    # A third `prefix` argument can be pass along to be prepended to
    # the string.
    def path(logical_path, fingerprint = true, prefix = nil)
      logger.warn "Sprockets::Environment#path is deprecated\n#{caller[0..2].join("\n")}"
      if fingerprint && asset = find_asset(logical_path.to_s.sub(/^\//, ''))
        url = asset.digest_path
      else
        url = logical_path
      end

      url = File.join(prefix, url) if prefix
      url = "/#{url}" unless url =~ /^\//

      url
    end

    # Deprecated: Similar to `path`, `url` returns a full url given a Rack `env`
    # Hash and a `logical_path`.
    def url(env, logical_path, fingerprint = true, prefix = nil)
      logger.warn "Sprockets::Environment#url is deprecated\n#{caller[0..2].join("\n")}"
      req = Rack::Request.new(env)

      url = req.scheme + "://"
      url << req.host

      if req.scheme == "https" && req.port != 443 ||
          req.scheme == "http" && req.port != 80
        url << ":#{req.port}"
      end

      url << path(logical_path, fingerprint, prefix)

      url
    end

    private
      def forbidden_request?(env)
        # Prevent access to files elsewhere on the file system
        #
        #     http://example.org/assets/../../../etc/passwd
        #
        env["PATH_INFO"].include?("..")
      end

      # Returns a 403 Forbidden response tuple
      def forbidden_response
        [ 403, { "Content-Type" => "text/plain", "Content-Length" => "9" }, [ "Forbidden" ] ]
      end

      # Returns a 404 Not Found response tuple
      def not_found_response
        [ 404, { "Content-Type" => "text/plain", "Content-Length" => "9", "X-Cascade" => "pass" }, [ "Not found" ] ]
      end

      # Returns a JavaScript response that re-throws a Ruby exception
      # in the browser
      def javascript_exception_response(exception)
        expire_index!
        err  = "#{exception.class.name}: #{exception.message}"
        body = "throw Error(#{err.inspect})"
        [ 200, { "Content-Type" => "application/javascript", "Content-Length" => Rack::Utils.bytesize(body).to_s }, [ body ] ]
      end

      # Returns a CSS response that hides all elements on the page and
      # displays the exception
      def css_exception_response(exception)
        expire_index!
        message   = "\n#{exception.class.name}: #{exception.message}"
        backtrace = "\n  #{exception.backtrace.first}"

        body = <<-CSS
          html {
            padding: 18px 36px;
          }

          head {
            display: block;
          }

          body {
            margin: 0;
            padding: 0;
          }

          body > * {
            display: none !important;
          }

          head:after, body:before, body:after {
            display: block !important;
          }

          head:after {
            font-family: sans-serif;
            font-size: large;
            font-weight: bold;
            content: "Error compiling CSS asset";
          }

          body:before, body:after {
            font-family: monospace;
            white-space: pre-wrap;
          }

          body:before {
            font-weight: bold;
            content: "#{escape_css_content(message)}";
          }

          body:after {
            content: "#{escape_css_content(backtrace)}";
          }
        CSS

        [ 200, { "Content-Type" => "text/css;charset=utf-8", "Content-Length" => Rack::Utils.bytesize(body).to_s }, [ body ] ]
      end

      # Escape special characters for use inside a CSS content("...") string
      def escape_css_content(content)
        content.
          gsub('\\', '\\\\005c ').
          gsub("\n", '\\\\000a ').
          gsub('"',  '\\\\0022 ').
          gsub('/',  '\\\\002f ')
      end

      # Compare the requests `HTTP_IF_MODIFIED_SINCE` against the
      # assets mtime
      def not_modified?(asset, env)
        env["HTTP_IF_MODIFIED_SINCE"] == asset.mtime.httpdate
      end

      # Compare the requests `HTTP_IF_NONE_MATCH` against the assets digest
      def etag_match?(asset, env)
        env["HTTP_IF_NONE_MATCH"] == etag(asset)
      end

      # Test if `?body=1` or `body=true` query param is set
      def body_only?(env)
        env["QUERY_STRING"].to_s =~ /body=(1|t)/
      end

      # Returns a 304 Not Modified response tuple
      def not_modified_response(asset, env)
        [ 304, {}, [] ]
      end

      # Returns a 200 OK response tuple
      def ok_response(asset, env)
        if body_only?(env)
          [ 200, headers(env, asset, Rack::Utils.bytesize(asset.body)), [asset.body] ]
        else
          [ 200, headers(env, asset, asset.length), asset ]
        end
      end

      def headers(env, asset, length)
        Hash.new.tap do |headers|
          # Set content type and length headers
          headers["Content-Type"]   = asset.content_type
          headers["Content-Length"] = length.to_s

          # Set caching headers
          headers["Cache-Control"]  = "public"
          headers["Last-Modified"]  = asset.mtime.httpdate
          headers["ETag"]           = etag(asset)

          # If the request url contains a fingerprint, set a long
          # expires on the response
          if attributes_for(env["PATH_INFO"]).path_fingerprint
            headers["Cache-Control"] << ", max-age=31536000"

          # Otherwise set `must-revalidate` since the asset could be modified.
          else
            headers["Cache-Control"] << ", must-revalidate"
          end
        end
      end

      # Helper to quote the assets digest for use as an ETag.
      def etag(asset)
        %("#{asset.digest}")
      end
  end
end
