#if DEBUG
import AppKit
import WebKit
import MDRCore

/// Reproducible diagnostics using a generated, fictional document in real WKWebView.
@MainActor enum NativePerformance {
    static func run(owner: AppDelegate, directory: URL) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure mdr reader performance")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            func stage(_ value: String) { try? value.write(to: directory.appendingPathComponent("stage.txt"), atomically: true, encoding: .utf8) }
            stage("Opening")
            let source = directory.appendingPathComponent("large-spec.md")
            let start = Date()
            let reader = try ReaderWindow(url: source, owner: owner)
            owner.windows[source.path] = reader
            reader.window.setContentSize(NSSize(width: 1440, height: 980))
            reader.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            reader.window.level = .floating
            reader.window.makeKeyAndOrderFront(nil)
            reader.window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            try await NativeSmoke.wait(reader, "!!document.querySelector('#document h1')")
            stage("Measuring")
            let opened = Date().timeIntervalSince(start) * 1000
            try await Task.sleep(nanoseconds: 500_000_000)
            let script = """
            const initial=window.mdr.performance(true),frames=[],initialElements=document.querySelectorAll('#document *').length;
            let background=document.hidden;
            const frame=()=>{if(document.hidden){background=true;return Promise.resolve();}return new Promise(resolve=>{requestAnimationFrame(resolve);setTimeout(resolve,100);});};
            const scroll=document.getElementById('scroll-area');
            let previous=performance.now();
            for(let i=0;i<180&&!background;i++){
              window.__mdrBenchStep='skim '+i;scroll.scrollTop=(scroll.scrollHeight-scroll.clientHeight)*i/179;
              await frame();
              const now=performance.now();frames.push(now-previous);previous=now;
            }
            frames.sort((a,b)=>a-b);
            const scrolling=window.mdr.performance(true);
            if(!background)await new Promise(resolve=>setTimeout(resolve,150));
            const settled=window.mdr.performance(true);
            const readingFrames=[];
            for(let i=0;i<120&&!background;i++){window.__mdrBenchStep='read '+i;scroll.scrollTop=2000+i*18;const before=performance.now();await frame();readingFrames.push(performance.now()-before);}
            readingFrames.sort((a,b)=>a-b);
            const reading=window.mdr.performance(true);
            window.__mdrBenchStep='comments';
            const value=structuredClone(window.__mdrLastState),feedback=[];
            for(let i=1;i<=60;i++){
              const exact='Partition '+i+' owns an independent queue.',start=value.source.indexOf(exact);
              const anchor={start,end:start+exact.length,exact};
              feedback.push({id:'perf-'+i,kind:'comment',body:'Please clarify the retry boundary.',author:'Maya',createdAt:'2026-09-23T12:00:00Z',createdAgainst:value.revision,anchor,originalAnchor:anchor,state:'attached',resolved:false,replies:[]});
            }
            value.feedback=feedback;
            for(let i=0;i<3;i++){window.mdr.receive(value);await frame();}
            const reviewing=window.mdr.performance(true);
            window.__mdrBenchStep='find';
            document.getElementById('find-input').value='Reservation';
            document.getElementById('find-input').dispatchEvent(new Event('input'));
            await frame();
            const finding=window.mdr.performance(true);
            document.getElementById('find-input').value='';document.getElementById('find-input').dispatchEvent(new Event('input'));
            scroll.scrollTop=0;await frame();await frame();
            return {background,initial,initialElements,scrolling,settled,reading,readingFrames:{median:background?null:readingFrames[60],p95:background?null:readingFrames[114],max:background?null:readingFrames.at(-1)},reviewing,finding,frames:{median:background?null:frames[90],p95:background?null:frames[171],max:background?null:frames.at(-1)},elements:document.querySelectorAll('#document *').length,codeBlocks:document.querySelectorAll('.code-block').length,codeLines:document.querySelectorAll('.code-line').length};
            """
            let watchdog: Task<Void, Never>? = ProcessInfo.processInfo.environment["MDR_BENCH_DEBUG"] == nil ? nil : Task { @MainActor in
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    if let step = try? await reader.webView.evaluateJavaScript("JSON.stringify({step:window.__mdrBenchStep,visibility:document.visibilityState,focus:document.hasFocus()})") { stage("\(step) visible=\(reader.window.isVisible) activeSpace=\(reader.window.isOnActiveSpace) occlusion=\(reader.window.occlusionState.rawValue) frame=\(reader.webView.frame)") }
                }
            }
            defer { watchdog?.cancel() }
            var result = try await reader.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
            stage("Writing report")
            result["openMilliseconds"] = opened
            result["sourceBytes"] = try Data(contentsOf: source).count
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("report.json"))
            print(String(data: data, encoding: .utf8)!)
            let image = try await reader.webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent("reader.png")) }
            reader.window.close()
            Darwin.exit(0)
        } catch {
            print("Performance run failed: \(error)")
            Darwin.exit(1)
        }
    }
}
#endif
