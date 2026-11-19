import AppKit
import Metal
import QuartzCore

// Minimal SDR BGRA8Unorm Metal test app: verifies libTrueHDR.dylib hooks CAMetalLayer +
// MTLCommandBuffer transparently (app still sees BGRA8Unorm while display receives >1.0x EDR).
final class SDRTestDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var layer: CAMetalLayer!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipe: MTLRenderPipelineState!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!

        let rect = NSRect(x: 100, y: 120, width: 640, height: 360)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TrueHDR SDR Metal Test"
        window.level = .floating

        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.frame = view.bounds
        layer.contentsScale = window.backingScaleFactor
        layer.drawableSize = CGSize(width: rect.width * layer.contentsScale, height: rect.height * layer.contentsScale)
        view.layer = layer
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vs(uint i [[vertex_id]]) {
            float2 p[3] = { {-1,-1}, {3,-1}, {-1,3} };
            VOut o; o.pos = float4(p[i], 0, 1); o.uv = p[i] * 0.5 + 0.5; return o;
        }
        fragment float4 fs(VOut in [[stage_in]]) {
            // Sky gradient + small dark bird silhouette + bright sun/specular disc
            float3 sky = mix(float3(0.38, 0.58, 0.87), float3(0.81, 0.87, 0.94), in.uv.y);
            float dBird = length((in.uv - float2(0.35, 0.55)) * float2(1.77, 1.0));
            if (dBird < 0.015) return float4(0.11, 0.12, 0.14, 1.0);
            float dSun = length((in.uv - float2(0.75, 0.65)) * float2(1.77, 1.0));
            if (dSun < 0.08) return float4(1.0, 0.98, 0.92, 1.0);
            return float4(sky, 1.0);
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = lib.makeFunction(name: "vs")
        rpd.fragmentFunction = lib.makeFunction(name: "fs")
        rpd.colorAttachments[0].pixelFormat = layer.pixelFormat // expects BGRA8Unorm!
        pipe = try! device.makeRenderPipelineState(descriptor: rpd)

        let cr = window.convertToScreen(view.frame)
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        print(String(format: "RECT %.0f,%.0f,%.0f,%.0f", cr.minX, screenH - cr.maxY, cr.width, cr.height))
        print("SDRTestDelegate ready: reported layer.pixelFormat=\(layer.pixelFormat.rawValue) wantsEDR=\(layer.wantsExtendedDynamicRangeContent)")
        fflush(stdout)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard let drawable = self.layer.nextDrawable() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let cb = self.queue.makeCommandBuffer()!
            let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(self.pipe)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let del = SDRTestDelegate()
app.delegate = del
app.run()
