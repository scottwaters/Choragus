/// SunoWebView.swift — Embedded WKWebView for browsing suno.com inside the app.
///
/// Shows Suno's own public site (e.g. `/explore`) so the user browses and
/// searches with Suno's real UI — no private API, no scraping. The only hook
/// is the current page URL: a `SunoWebController` publishes it so the host
/// toolbar can detect when the user is viewing a public song (`/song/<uuid>`
/// or `/s/<code>`) and offer "Play on Sonos".
///
/// Suno's site is a client-rendered SPA, so route changes happen via
/// `history.pushState` rather than full navigations. A small injected script
/// reports those route changes through a `WKScriptMessageHandler` (the
/// navigation delegate alone would miss them).
import SwiftUI
import WebKit
import AppKit
import SonosKit

/// Live state + command surface for an embedded Suno web view. Owned by the
/// host view as a `@StateObject`; the `SunoWebView` coordinator writes the
/// published fields on the main thread (WebKit delegate / message callbacks).
final class SunoWebController: ObservableObject {
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false

    /// Invoked when the user activates a song's in-page play button (left
    /// click) or picks "Play Now" from the overridden right-click menu.
    var onPlay: ((URL) -> Void)?
    /// Invoked when the user picks "Add to Queue" from the right-click menu.
    var onQueue: ((URL) -> Void)?
    /// Invoked when the user clicks a page-level "play all" button on a
    /// playlist / genre page — the full ordered list of song URLs.
    var onPlayAll: (([URL]) -> Void)?
    /// Invoked when the user clicks the play button on a playlist / album card
    /// (a `/playlist/<id>` link) — the playlist is fetched and played.
    var onPlaylist: ((URL) -> Void)?

    fileprivate weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
}

struct SunoWebView: NSViewRepresentable {
    let initialURL: URL
    let controller: SunoWebController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Self.navScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.interceptScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        ucc.add(context.coordinator, name: "sunoNav")
        ucc.add(context.coordinator, name: "sunoAct")

        let config = WKWebViewConfiguration()
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        controller.webView = webView
        sonosDebugLog("[SUNO] web view created, loading \(initialURL.absoluteString)")
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: SunoWebController
        init(controller: SunoWebController) { self.controller = controller }

        /// Called on the main thread by WebKit — safe to publish directly.
        private func sync(_ url: URL?) {
            controller.currentURL = url
            controller.canGoBack = controller.webView?.canGoBack ?? false
            controller.canGoForward = controller.webView?.canGoForward ?? false
            sonosDebugLog("[SUNO] url=\(url?.absoluteString ?? "nil")")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { sync(webView.url) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sonosDebugLog("[SUNO] didFinish load")
            sync(webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            sonosDebugLog("[SUNO] provisional load FAILED: \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            sonosDebugLog("[SUNO] load FAILED: \(error.localizedDescription)")
        }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "sunoNav", let href = message.body as? String {
                sync(URL(string: href))
                return
            }
            guard message.name == "sunoAct",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "play":
                if let h = body["href"] as? String, let u = URL(string: h) {
                    sonosDebugLog("[SUNO] in-page PLAY \(h)")
                    controller.onPlay?(u)
                }
            case "menu":
                let kind = body["kind"] as? String ?? "song"
                let url = (body["href"] as? String).flatMap { URL(string: $0) }
                let hrefs = (body["hrefs"] as? [String])?.compactMap { URL(string: $0) } ?? []
                sonosDebugLog("[SUNO] in-page MENU kind=\(kind)")
                showMenu(kind: kind, url: url, hrefs: hrefs)
            case "playAll":
                if let arr = body["hrefs"] as? [String] {
                    let urls = arr.compactMap { URL(string: $0) }
                    sonosDebugLog("[SUNO] in-page PLAY ALL count=\(urls.count)")
                    controller.onPlayAll?(urls)
                }
            case "playlist":
                if let h = body["href"] as? String, let u = URL(string: h) {
                    sonosDebugLog("[SUNO] in-page PLAYLIST \(h)")
                    controller.onPlaylist?(u)
                }
            default:
                break
            }
        }

        /// Override Suno's right-click with a Sonos Play Now / Add to Queue menu,
        /// shown at the actual cursor location (screen coordinates).
        private func showMenu(kind: String, url: URL?, hrefs: [URL]) {
            let menu = NSMenu()
            func item(_ title: String, _ action: Selector, _ obj: Any) -> NSMenuItem {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self
                i.representedObject = obj
                return i
            }
            switch kind {
            case "playlist":
                if let url { menu.addItem(item("Play Playlist on Sonos", #selector(menuPlaylist(_:)), url)) }
            case "playall":
                if !hrefs.isEmpty { menu.addItem(item("Play All on Sonos", #selector(menuPlayAll(_:)), hrefs)) }
            default:
                if let url {
                    menu.addItem(item("Play Now on Sonos", #selector(menuPlay(_:)), url))
                    menu.addItem(item("Add to Sonos Queue", #selector(menuQueue(_:)), url))
                }
            }
            guard !menu.items.isEmpty else { return }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        @objc private func menuPlay(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL { controller.onPlay?(url) }
        }

        @objc private func menuPlaylist(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL { controller.onPlaylist?(url) }
        }

        @objc private func menuPlayAll(_ sender: NSMenuItem) {
            if let urls = sender.representedObject as? [URL] { controller.onPlayAll?(urls) }
        }

        @objc private func menuQueue(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL { controller.onQueue?(url) }
        }
    }

    /// Hooks SPA history mutations and forwards the new URL to native code.
    private static let navScript = """
    (function(){
      function n(){try{window.webkit.messageHandlers.sunoNav.postMessage(location.href);}catch(e){}}
      var p=history.pushState; history.pushState=function(){p.apply(this,arguments);n();};
      var r=history.replaceState; history.replaceState=function(){r.apply(this,arguments);n();};
      window.addEventListener('popstate',n);
      n();
    })();
    """

    /// Intercepts in-page play-button clicks and right-clicks on song tiles,
    /// routing them to Sonos instead of Suno's in-browser player. Each tile is
    /// a `<a href="…/song/<uuid>">`, which is the stable signal used to identify
    /// the song. Runs in the capture phase so it preempts Suno's own handlers.
    private static let interceptScript = """
    (function(){
      function songHref(node){
        if(!node||!node.closest)return null;
        var a=node.closest('a[href*="/song/"]'); if(a)return a.href;
        var c=node.closest('[data-clip-id]'); if(c)return 'https://suno.com/song/'+c.getAttribute('data-clip-id');
        // Play button that's a sibling of (not inside) the song link: search
        // the enclosing row/card, but only accept it when there's exactly one
        // song link there (otherwise it's ambiguous, e.g. a list section).
        var box=node.closest('[role="button"],li,article,[class*="row"]');
        if(box){ var ls=box.querySelectorAll('a[href*="/song/"]'); if(ls.length===1) return ls[0].href; }
        // Library / create / carousel cards have no /song/ link — the play
        // overlay is a <div role="button" aria-label="Play …"> with an
        // <img …/image_large_<uuid>.jpeg>. The clip id is in the art URL.
        var card=node.closest('[role="button"],li,article,[class*="clip"],[class*="card"]');
        if(card){
          var img=card.querySelector('img[src*="suno.ai/image"],img[data-src*="suno.ai/image"]');
          if(img){
            var s=img.getAttribute('src')||img.getAttribute('data-src')||'';
            var mm=s.match(/image(?:_large)?_([0-9a-fA-F-]{36})/);
            if(mm) return 'https://suno.com/song/'+mm[1];
          }
        }
        return null;
      }
      // True when the user clicked Suno's play-triangle icon (path starts
      // "M6 18.705"). Keys on the icon's own <svg>/<path>, so it fires for the
      // play control in song rows (which are <div role="button">, not
      // <button>), playlist/genre headers and song pages alike — but not for
      // other icons (heart, more, shuffle, expand) or the pause icon.
      function clickedPlay(node){
        if(!node)return false;
        // the play-triangle icon itself
        if(node.tagName&&node.tagName.toLowerCase()==='path'&&((node.getAttribute('d')||'').indexOf('M6 18.705')===0))return true;
        var svg=node.closest&&node.closest('svg');
        if(svg&&svg.querySelector('path[d^="M6 18.705"]'))return true;
        // a <button>/[role=button] that CONTAINS the play icon — covers clicks
        // on the button's padding (e.target is the button, not the svg), e.g.
        // the round overlay play button.
        var b=node.closest&&node.closest('button,[role="button"]');
        if(b&&b.querySelector&&b.querySelector('path[d^="M6 18.705"]'))return true;
        // Explicit "Play" / "Play <title>" labels (cards) — excludes
        // "Playlist…", "Pause", and "Playbar:…".
        return !!(node.closest&&node.closest('[aria-label="Play"],[aria-label^="Play "]'));
      }
      // Collect each song link once, de-duplicated by clip UUID — a tile
      // often has several anchors to the same song (art + title), which would
      // otherwise enqueue the track multiple times.
      function allSongHrefs(){
        var seen={},out=[];
        document.querySelectorAll('a[href*="/song/"]').forEach(function(a){
          var m=a.href.match(/\\/song\\/([0-9a-fA-F-]{36})/);
          if(m&&!seen[m[1]]){seen[m[1]]=1;out.push(a.href);}
        });
        return out;
      }
      // The global player bar is a fixed/sticky element in the lower part of
      // the viewport. Its play/pause must be left to Suno — never intercepted.
      function inFixedFooter(node){
        var el=node;
        while(el&&el!==document.body){
          try{
            var pos=getComputedStyle(el).position;
            if(pos==='fixed'||pos==='sticky'){
              var r=el.getBoundingClientRect();
              if(r.top>window.innerHeight*0.6)return true;
            }
          }catch(_){}
          el=el.parentElement;
        }
        return false;
      }
      function post(m){try{window.webkit.messageHandlers.sunoAct.postMessage(m);}catch(e){}}
      function dbg(m){post({type:'debug',msg:m});}   // TEMP: left-click divert diagnostics
      // Suno may start its own player on pointerdown before our click handler
      // runs. Rather than fight the events (which breaks the click), let it
      // start, then pause its <audio>/<video> repeatedly for ~2s so only Sonos
      // is heard. Doesn't mute (so Suno's player is usable later if needed).
      function silenceSuno(){
        var n=0,iv=setInterval(function(){
          document.querySelectorAll('audio,video').forEach(function(a){try{a.pause();}catch(_){}});
          if(++n>=14)clearInterval(iv);
        },150);
      }
      var collectionUntil=0;
      // Set when a single-track click was handled via the public DOM /song/
      // URL; suppresses the audio-hook divert during that window so it doesn't
      // also post the NON-PUBLIC blob clip id (which fails to resolve).
      var clickHandledUntil=0;
      function uuidFromAny(s){var m=(s||'').match(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/);return m?m[0].toLowerCase():null;}
      // Audio-layer catch: fires whenever Suno actually starts a track, no
      // matter which button/page triggered it. If the clip id is in the audio
      // src, pause the browser audio and divert to Sonos. During a play-all /
      // playlist hand-off we only silence (that collection is already going to
      // Sonos via the click path).
      document.addEventListener('play',function(e){
        var el=e.target; if(!el||(el.tagName!=='AUDIO'&&el.tagName!=='VIDEO'))return;
        // Muted elements are the autoplaying card-art videos — never divert.
        if(el.muted){dbg('play: muted '+el.tagName+', ignore');return;}
        var src=el.currentSrc||el.src||'';
        if(Date.now()<collectionUntil||Date.now()<clickHandledUntil){dbg('play: click/collection handled, silence only');try{el.pause();}catch(_){}return;}
        var ua=(navigator.userActivation?(navigator.userActivation.isActive?'active':'inactive'):'none');
        // Only divert playback the USER started — Suno autoplays a featured
        // track on load with no transient user activation; ignore that so it
        // doesn't silently replace the Sonos queue. Missing userActivation
        // (older WebKit) is treated as "not active" so autoplay can't slip
        // through the gate.
        if(!navigator.userActivation || navigator.userActivation.isActive===false){dbg('play: GATED userActivation='+ua+' src='+src.slice(0,80));try{el.pause();}catch(_){}return;}
        var uuid=uuidFromAny(src);
        dbg('play: ua='+ua+' uuid='+(uuid||'NONE')+' src='+src.slice(0,90));
        if(uuid){try{el.pause();}catch(_){}post({type:'play',href:'https://suno.com/song/'+uuid});}
        else{dbg('play: no uuid in audio src — cannot divert');}
      },true);
      // Climb from the click to the smallest container that unambiguously
      // identifies ONE item: a single /song/ link, else a single artwork image
      // (clip id lives in the .../image_large_<uuid>.jpeg URL), else a single
      // /playlist/ link. No hard-coded class names — adapts to Suno's markup.
      function resolveFromClick(node){
        // The anchor the click is INSIDE of is the most direct, authoritative
        // signal. On /explore carousels the play control sits within the card's
        // <a href="/song/…">; querySelectorAll below only sees DESCENDANT links,
        // so it never finds that ancestor anchor and fell through to the cover
        // image — which on explore is a different, often non-public clip version
        // of the same song (observed: cover 8952215e notPublic, link 156a8275
        // playable). The right-click add then silently failed while left-click
        // play still worked (play diverts via the audio hook, not this resolver).
        var inSong=node.closest&&node.closest('a[href*="/song/"]');
        if(inSong)return {kind:'song',url:inSong.href};
        // Preference order while climbing: (1) the smallest container with
        // exactly one /song/ link; (2) the nearest /song/ link from a block
        // that has several — a featured/hero tile is IMAGE-ONLY (no anchor of
        // its own) and sits in a block whose first /song/ link in document
        // order is its playable clip; (3) the cover-image uuid, a LAST resort
        // because a featured tile's cover is often a different, NON-PUBLIC clip
        // version than the playable song (observed on the first /explore card:
        // cover 8952215e → notPublic, song 156a8275 → playable). Picking the
        // image first made the first card's add fail while the others worked.
        var el=node,hops=0,imgFallback=null,songFallback=null;
        while(el&&el!==document.body&&hops<8){
          if(el.querySelectorAll){
            var songs=el.querySelectorAll('a[href*="/song/"]');
            if(songs.length===1)return {kind:'song',url:songs[0].href};
            if(songs.length===0){
              // A playlist link is definitive — check it BEFORE the cover image,
              // since a playlist card also has an image_large_<uuid> cover that
              // would otherwise resolve to a single song.
              var pls=el.querySelectorAll('a[href*="/playlist/"]');
              if(pls.length===1)return {kind:'playlist',url:pls[0].href};
              if(!imgFallback){
                var imgs=el.querySelectorAll('img[src*="suno.ai/"],img[data-src*="suno.ai/"]');
                if(imgs.length===1){
                  var s=imgs[0].getAttribute('src')||imgs[0].getAttribute('data-src')||'';
                  var m=s.match(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/);
                  if(m)imgFallback='https://suno.com/song/'+m[0].toLowerCase();
                }
              }
            } else if(!songFallback){
              // More than one song link at this level (no clean single-song
              // container yet). The first in document order is this tile's own
              // song — remember it, preferred over the cover image below.
              songFallback=songs[0].href;
            }
          }
          el=el.parentElement;hops++;
        }
        if(songFallback)return {kind:'song',url:songFallback};
        if(imgFallback)return {kind:'song',url:imgFallback};
        if(location.pathname.indexOf('/song/')===0)return {kind:'song',url:location.href};
        if(location.pathname.indexOf('/playlist/')===0)return {kind:'playall'};
        return null;
      }
      document.addEventListener('click',function(e){
        if(!clickedPlay(e.target)){return;}     // only override a play affordance
        dbg('click: play affordance hit');
        if(inFixedFooter(e.target)){dbg('click: in fixed footer, leaving to Suno');return;}    // leave the global player bar alone
        var r=resolveFromClick(e.target);
        dbg('click: resolve kind='+(r?r.kind:'null'));
        // Collections have no single audio element to catch, so resolve + play
        // them here.
        if(r&&r.kind==='playlist'){e.preventDefault();e.stopImmediatePropagation();post({type:'playlist',href:r.url});collectionUntil=Date.now()+6000;silenceSuno();return;}
        if(r&&r.kind==='playall'){var all=allSongHrefs();if(all.length){e.preventDefault();e.stopImmediatePropagation();post({type:'playAll',hrefs:all});collectionUntil=Date.now()+6000;silenceSuno();}return;}
        // Single track: play the PUBLIC DOM /song/ URL (the same id the
        // working right-click path uses). The audio-layer blob carries Suno's
        // internal NON-PUBLIC clip id, which fails to resolve (notPublic), so
        // we must not divert off it. Suppress that divert for a short window.
        if(r&&r.kind==='song'){e.preventDefault();e.stopImmediatePropagation();post({type:'play',href:r.url});clickHandledUntil=Date.now()+6000;silenceSuno();return;}
      },true);
      document.addEventListener('contextmenu',function(e){
        if(inFixedFooter(e.target))return;
        var r=resolveFromClick(e.target);
        if(!r)return;
        e.preventDefault();e.stopImmediatePropagation();
        if(r.kind==='song'){post({type:'menu',kind:'song',href:r.url});}
        else if(r.kind==='playlist'){post({type:'menu',kind:'playlist',href:r.url});}
        else if(r.kind==='playall'){post({type:'menu',kind:'playall',hrefs:allSongHrefs()});}
      },true);
      // Hide Suno's own player bar — playback is on Sonos, so its transport
      // controls are confusing. It's a normal-flow <div data-playbar="true">
      // (not a fixed overlay), so a CSS rule on that stable attribute hides it
      // now and across re-renders. Diversion is unaffected (the hidden bar's
      // <audio> still fires 'play' and is paused by the audio hook).
      (function(){
        var s=document.createElement('style');
        s.textContent='[data-playbar="true"]{display:none!important}';
        (document.head||document.documentElement).appendChild(s);
      })();
    })();
    """
}
