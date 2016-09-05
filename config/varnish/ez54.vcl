// Varnish 4 style - eZ 5.4+ / 2014.09+
// Complete VCL example

vcl 4.0;

import std;

// Our Backend - Assuming that web server is listening on port 80
// Replace the host to fit your setup
backend ezpublish {
    .host = "web";
    .port = "8080";
}

// ACL for invalidators IP - only other containers
acl invalidators {
    "127.0.0.1";
    "172.18.0.0"/24;
    "172.19.0.0"/24;
    //"192.168.1.0"/16;
}

// ACL for debuggers IP - since these are dev/uat envs: everybody :-)
acl debuggers {
    "127.0.0.1"/0;

    "127.0.0.1";
    //"192.168.1.0"/16;
}

// ACL for the proxies in front of Varnish (e.g. Nginx terminating https) - only other containers
acl proxies {
    "172.18.0.0"/24;
    "172.19.0.0"/24;
}

// Called at the beginning of a request, after the complete request has been received
sub vcl_recv {

    // Set the backend
    set req.backend_hint = ezpublish;

    # Advertise Symfony for ESI support

    if(!req.url ~ "/content/versionview/") {
        set req.http.Surrogate-Capability = "abc=ESI/1.0";
    }

    // Add a unique header containing the client address (only for master request)
    // Please note that /_fragment URI can change in Symfony configuration
    // take care of requests getting 'restarted' because of the user-hash lookup
    if (req.url !~ "^/_fragment" && req.restarts == 0) {
        // only accept the x-forwarded-for header if the remote-proxy is trusted
        // also we add our ip to the list of forwarders, as it is logged by Apache by default
        if (req.http.x-forwarded-for && client.ip ~ proxies) {
            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + server.ip;
        } else {
            set req.http.X-Forwarded-For = "" + client.ip + ", " + server.ip;
        }
    }

    // Trigger cache purge if needed
    call ez_purge;

    // Normalize the Accept-Encoding headers
    if (req.http.Accept-Encoding) {
        if (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    // Don't cache requests other than GET and HEAD.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    // Don't cache Authenticate & Authorization
    // You may remove this when using REST API with basic auth.
    if (req.http.Authenticate || req.http.Authorization) {
        if (client.ip ~ debuggers) {
            set req.http.X-Debug = "Not Cached according to configuration (Authorization)";
        }
        return (hash);
    }

    # Don't cache symfony toolbar
    if (req.url ~ "^/_(profiler|wdt)") {
        return (pass);
    }

    // Do a standard lookup on assets
    // Note that file extension list below is not extensive, so consider completing it to fit your needs.
    // @todo we should also take into account that content names might end with this. It has to be anchored at start of url!
    if (req.url ~ "\.(css|js|gif|jpe?g|bmp|png|tiff?|ico|img|tga|wmf|svg|swf|ico|mp3|mp4|m4a|ogg|mov|avi|wmv|zip|gz|pdf|ttf|eot|wof)$") {
        return (hash);
    }

    // Retrieve client user hash and add it to the forwarded request.
    call ez_user_hash;

    // If it passes all these tests, do a lookup anyway.
    return (hash);
}

// Called when the requested object has been retrieved from the backend
sub vcl_backend_response {

    if (bereq.http.accept ~ "application/vnd.fos.user-context-hash"
        && beresp.status >= 500
    ) {
        return (abandon);
    }

    // Optimize to only parse the Response contents from Symfony
    if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
        unset beresp.http.Surrogate-Control;
        set beresp.do_esi = true;
    }

    // Allow stale content, in case the backend goes down or cache is not fresh any more
    // make Varnish keep all objects for 1 hours beyond their TTL
    set beresp.grace = 1h;
}

// Handle purge
// You may add FOSHttpCacheBundle tagging rules
// See http://foshttpcache.readthedocs.org/en/latest/varnish-configuration.html#id4
sub ez_purge {

    if (req.method == "BAN") {
        if (!client.ip ~ invalidators) {
            return (synth(405, "Method not allowed - ip: "+ client.ip));
        }

        if (req.http.X-Location-Id) {
            if ( req.http.X-Location-Id == "*" ) {
                // Purge all locations
                ban( "obj.http.X-Location-Id ~ ^[0-9]+$" );
                if (client.ip ~ debuggers) {
                    set req.http.X-Debug = "Purge all locations done.";
                }
            } else {
                // Purge location by its locationId
                ban( "obj.http.X-Location-Id ~ \b" + req.http.X-Location-Id +"\b");
                if (client.ip ~ debuggers) {
                    set req.http.X-Debug = "Purge of content connected to the location id(" + req.http.X-Location-Id + ") done.";
                }
            }
        } elseif ( req.http.X-Match ) {
             ban( "req.url ~ " + req.http.X-Match );
             if (client.ip ~ debuggers) {
                 set req.http.X-Debug = "Purge of urls " + req.http.X-Match + " done";
             }
        }

        // necessary, otherwise the request goes through to the website
        return (synth(200, "Banned"));
    }
}

// Sub-routine to get client user hash, for context-aware HTTP cache.
sub ez_user_hash {

    // Prevent tampering attacks on the hash mechanism
    if (req.restarts == 0
        && (req.http.accept ~ "application/vnd.fos.user-context-hash"
            || req.http.x-user-hash
        )
    ) {
        return (synth(400));
    }

    if (req.restarts == 0 && (req.method == "GET" || req.method == "HEAD")) {
        // Anonymous user => Set a hardcoded anonymous hash
        if (req.http.Cookie !~ "eZSESSID" && !req.http.authorization) {
            set req.http.X-User-Hash = "38015b703d82206ebc01d17a39c727e5";
        }
        // Pre-authenticate request to get shared cache, even when authenticated
        else {
            set req.http.x-fos-original-url    = req.url;
            set req.http.x-fos-original-accept = req.http.accept;
            set req.http.x-fos-original-cookie = req.http.cookie;
            // Clean up cookie for the hash request to only keep session cookie, as hash cache will vary on cookie.
            set req.http.cookie = ";" + req.http.cookie;
            set req.http.cookie = regsuball(req.http.cookie, "; +", ";");
            set req.http.cookie = regsuball(req.http.cookie, ";(eZSESSID[^=]*)=", "; \1=");
            set req.http.cookie = regsuball(req.http.cookie, ";[^ ][^;]*", "");
            set req.http.cookie = regsuball(req.http.cookie, "^[; ]+|[; ]+$", "");

            set req.http.accept = "application/vnd.fos.user-context-hash";
            set req.url = "/_fos_user_context_hash";

            // Force the lookup, the backend must tell how to cache/vary response containing the user hash

            return (hash);
        }
    }

    // Rebuild the original request which now has the hash.
    if (req.restarts > 0
        && req.http.accept == "application/vnd.fos.user-context-hash"
    ) {
        set req.url         = req.http.x-fos-original-url;
        set req.http.accept = req.http.x-fos-original-accept;
        set req.http.cookie = req.http.x-fos-original-cookie;

        unset req.http.x-fos-original-url;
        unset req.http.x-fos-original-accept;
        unset req.http.x-fos-original-cookie;

        // Force the lookup, the backend must tell not to cache or vary on the
        // user hash to properly separate cached data.

        return (hash);
    }
}

sub vcl_deliver {
    // On receiving the hash response, copy the hash header to the original
    // request and restart.
    if (req.restarts == 0
        && resp.http.content-type ~ "application/vnd.fos.user-context-hash"
    ) {
        set req.http.x-user-hash = resp.http.x-user-hash;

        return (restart);
    }

    // If we get here, this is a real response that gets sent to the client.

    // Remove the vary on context user hash, this is nothing public. Keep all
    // other vary headers.
    set resp.http.Vary = regsub(resp.http.Vary, "(?i),? *x-user-hash *", "");
    set resp.http.Vary = regsub(resp.http.Vary, "^, *", "");
    if (resp.http.Vary == "") {
        unset resp.http.Vary;
    }

    // Sanity check to prevent ever exposing the hash to a client.
    unset resp.http.x-user-hash;

    // Remove cache-control headers on content pages, as we do not want downstream proxies/caches to cache these
    if (req.url !~ "\.(css|js|gif|jpe?g|bmp|png|tiff?|ico|img|tga|wmf|svg|swf|ico|mp3|mp4|m4a|ogg|mov|avi|wmv|zip|gz|pdf|ttf|eot|wof)$") {
        unset resp.http.cache-control;
    }

    // Since this is a demo server, *always* add debug info
    if ((client.ip ~ proxies && std.ip(regsub(req.http.X-Forwarded-For, "^(([0-9]{1,3}\.){3}[0-9]{1,3}),(.*)$", "\1"), "0.0.0.0") ~ debuggers) || (client.ip ~ debuggers)) {
        if (obj.hits > 0) {
            set resp.http.X-Cache = "HIT";
            set resp.http.X-Cache-Hits = obj.hits;
        } else {
            set resp.http.X-Cache = "MISS";
        }
    } else {
        unset resp.http.X-Location-Id;
        unset resp.http.Via;
        unset resp.http.X-Varnish;
        unset resp.http.Server;
    }
}
