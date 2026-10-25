# cordova-plugin-app-scheme-cors

iOS only. cordova-ios 7+ serves the bundled `www` folder through a `WKURLSchemeHandler` on the
custom scheme configured in `config.xml` (`<preference name="scheme" value="app" />`,
`<preference name="hostname" value="localhost" />`), i.e. `app://localhost/<path>`.
WKWebView cannot intercept `http`/`https`, so this is the only way to reach local files from a
page loaded from a remote server. Cordova's own handler sends no CORS headers, though, so a
remote origin can only use the files through plain `<script>`, `<link>` and `<img>` tags:
`fetch`/XHR and `@font-face` loads are blocked by the browser.

This plugin implements `CDVPluginSchemeHandler` and takes over every request on the app scheme
that carries an `Origin` header (cross-origin `fetch`, XHR, fonts, `crossorigin` tags) plus the
`OPTIONS` preflight, and answers from the `www` folder with:

```
Access-Control-Allow-Origin: <the request's Origin>
Vary: Origin
Accept-Ranges: bytes
Cache-Control: no-cache
```

Requests without an `Origin` header are left to Cordova's default handler, so nothing else changes.
Only files inside the bundled `www` folder are served (Cordova's `_app_file_` escape hatch is not
honoured for CORS requests). `Range` requests are supported.

## Install

```
cordova plugin add https://github.com/ochakov/cordova-plugin-app-scheme-cors.git
```

## Restricting origins

By default any origin is allowed. To restrict, add a preference to `config.xml` with a
comma-separated list of origins; `*` is accepted as a wildcard for a host label:

```xml
<preference name="AppSchemeCorsOrigins" value="https://online.example.com,https://*.example.com" />
```

A request from another origin is handed back to Cordova's handler, which serves the file without
CORS headers, so the browser blocks it as before.

## Usage from the remote page

```js
const r = await fetch('app://localhost/pdfmake.js');
```

```css
@font-face { font-family: X; src: url(app://localhost/fonts/x.woff2); }
```

The page's Content-Security-Policy must allow the scheme (for example `default-src app://*`).
