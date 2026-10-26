# cordova-plugin-app-scheme-cors

Serves the bundled `www` folder of a Cordova iOS app over the custom `app://` scheme **with CORS
headers**, so a web client loaded from a remote server can `fetch` local assets and load local
web fonts from the app bundle, and **registers the scheme as secure** so that an `https://` page may
load `app://` scripts, styles and fonts at all (WebKit otherwise blocks them as mixed content).

- Platform: iOS only (cordova-ios 7 and 8, WKWebView). On Android nothing is needed: cordova-android
  already serves `https://localhost/...` through `WebViewAssetLoader`.
- No JavaScript API. Install it and use `app://localhost/<path>` URLs from your page.

## The problem

cordova-ios 7+ loads local content through a `WKURLSchemeHandler` on the scheme configured in
`config.xml`:

```xml
<preference name="scheme" value="app" />
<preference name="hostname" value="localhost" />
```

so a file `www/fonts/x.ttf` is reachable as `app://localhost/fonts/x.ttf`. WKWebView does not allow
a scheme handler for `http` or `https`, so this is the only way to reach bundled files from a page
that was loaded from a remote origin (a "shell" app whose UI lives on a web server).

The handler shipped with cordova-ios sends no CORS headers. `app://localhost` is a different origin
from `https://your.server`, so everything the browser subjects to CORS fails from the remote page:

- `fetch()` and `XMLHttpRequest`
- `@font-face { src: url(app://localhost/fonts/x.ttf) }` (font loads are always CORS requests)
- `<script crossorigin>`, `<link crossorigin>`, `<img crossorigin>`

Plain `<script>`, `<link rel="stylesheet">` and `<img>` tags without `crossorigin` keep working
without this plugin.

## What the plugin does

It implements Cordova's `CDVPluginSchemeHandler` protocol (`overrideSchemeTask:`), which lets a plugin
take over requests on the app scheme before the default handler runs. The plugin handles:

- every `GET`/`HEAD` request on the app scheme that carries an `Origin` header (that is, every
  cross-origin request the browser makes), and
- every `OPTIONS` preflight.

Requests without an `Origin` header, in particular the app's own same-origin page loads, are left to
cordova-ios's default handler, so nothing else in the app changes.

Responses are read from the bundled `www` folder and carry:

```
Access-Control-Allow-Origin: <the request's Origin>
Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Content-Type
Vary: Origin
Accept-Ranges: bytes
Cache-Control: no-cache
Content-Type: <from the file extension>
```

Details:

- `Range` requests are honoured (`206 Partial Content`, `416` when out of range).
- `HEAD` returns the headers only.
- A missing file yields a `404` that still carries the CORS headers, so the page sees a proper
  error instead of an opaque network failure.
- Only files inside the bundled `www` folder are served. `..` segments and cordova-ios's
  `_app_file_` escape hatch are refused for CORS requests.
- MIME types for web fonts and scripts (`woff`, `woff2`, `ttf`, `otf`, `js`, `mjs`, `css`, `json`,
  `svg`, `wasm`, ...) are mapped explicitly; everything else uses the system `UTType` lookup.
- Preflights are answered with `204`, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, the
  requested headers echoed back and a one day `Access-Control-Max-Age`.

## Mixed content: `app://` from an `https://` page

CORS headers are not enough when the page itself comes from `https://`. WebKit's mixed-content check
treats every URL whose scheme is not `https`/`wss` (or registered as secure) as insecure, so a page
loaded from `https://your.server` that references `app://localhost/...` gets

```
[blocked] The page at https://your.server/... requested insecure content from app://localhost/cordova.js.
This content was blocked and must be served over HTTPS.
```

for `<script>`, `<link rel="stylesheet">`, `@font-face`, `fetch()`/`XMLHttpRequest`, workers and
`<iframe>`. The request is dropped inside the web content process and never reaches any scheme
handler, so no plugin can answer it. Only `<img>`, `<audio>` and `<video>` are exempt (WebKit lets
"upgradable" content through for scheme-handler schemes).

The only switch WebKit offers is `-[WKProcessPool _registerURLSchemeAsSecure:]`. The plugin calls it
for the configured scheme, after which `app://` URLs count as secure and load like `https://` ones.
Nothing else changes: cross-origin requests are still subject to CORS, which is what the rest of this
plugin is for.

Timing matters. WebKit hands the list of secure schemes to a web content process when that process
launches, and it launches the processes as soon as cordova-ios creates the `WKWebView`, before any
plugin's `pluginInitialize` runs; a registration made from there would depend on WebKit forwarding it
to a process that is already starting. The plugin therefore hooks
`-[WKWebViewConfiguration setURLSchemeHandler:forURLScheme:]` (installed from its `+load`): cordova-ios
calls that right before it creates the web view, which is the moment the app scheme is known and still
before any process exists. The preferences are read directly from the bundled `config.xml` at that
point. If the hook never fires, `pluginInitialize` registers the scheme anyway and logs that it may be
too late.

Things to know:

- **It is a private WebKit method** (underscore prefix, declared in `WKProcessPoolPrivate.h`, no public
  equivalent; Apple feedback FB18346540 asks for one). The plugin looks it up at runtime with
  `NSSelectorFromString` and skips the call, with a log line, when the OS does not have it. App Store
  review can flag private selectors (`ITMS-90338`); whether to ship it is your decision.
- The registration is process-wide (WebKit keeps it in global settings since iOS 15, when
  `WKProcessPool` stopped mattering), so it applies to every `WKWebView` in the app.
- To keep the old behaviour, turn it off in `config.xml`:

  ```xml
  <preference name="AppSchemeRegisterAsSecure" value="false" />
  ```

## Install

```sh
cordova plugin add https://github.com/ochakov/cordova-plugin-app-scheme-cors.git
```

Requires cordova-ios 7.0.0 or newer and the custom scheme (the default `app` scheme; `file://`
loading has no scheme handler and is not supported).

## Restricting origins

By default any origin is allowed. To allow only your own servers, add a preference to `config.xml`
with a comma-separated list of origins. `*` matches one host label:

```xml
<preference name="AppSchemeCorsOrigins" value="https://online.example.com,https://*.example.com" />
```

A request from any other origin is handed back to the default cordova-ios handler, which serves the
file without CORS headers, so the browser blocks it exactly as before.

## Usage from the remote page

```js
const response = await fetch('app://localhost/data/config.json');
const json = await response.json();
```

```css
@font-face {
  font-family: 'MyFont';
  src: url('app://localhost/fonts/MyFont.woff2') format('woff2');
}
```

```html
<script src="app://localhost/vendor/pdfmake.min.js"></script>
```

If the page sets a Content-Security-Policy it must allow the scheme explicitly: `*` in a CSP source
list matches network schemes only, not custom ones.

```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'self' https: app://*; font-src 'self' app://*; script-src 'self' https: app://* 'unsafe-inline'">
```

Note that `response.headers.get('Access-Control-Allow-Origin')` returns `null` in the page: browsers
never expose the CORS control headers themselves, only the headers listed in
`Access-Control-Expose-Headers`.

## Tested

cordova-ios 8.1.1, iOS 27 simulator: cross-origin `fetch` (200 and 404), `Range` (206 with
`Content-Range` visible to the page), a preflighted request with a custom header, `HEAD`, a
`@font-face` load confirmed by `document.fonts.check()`, and a path traversal attempt (404).
Mixed content (cordova-ios 8.1.1, iOS 27.0 simulator, a remote `https://` page that inserts
`<script src="app://localhost/cordova.js">`): with `AppSchemeRegisterAsSecure=false` the script element
fires `error`, `window.cordova` stays undefined, a cross-origin `fetch` of the same URL fails with
"Load failed" and nothing reaches the scheme handler; with the default setting the handler serves
`cordova.js`, `cordova_plugins.js` and every plugin file, `window.cordova` exists at `load`,
`deviceready` fires and the `fetch` returns 200. Images pinged from the page reach the handler in both
cases, as expected for upgradable content.

## License

MIT
