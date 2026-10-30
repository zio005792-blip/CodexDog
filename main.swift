// CodexDog —— 点一下就清理 Codex 会话里的历史图片的桌宠
// 平时躲起来；在屏幕右下角来回晃鼠标，鼠标变成淀粉肠，小黑就跑出来讨吃的
import AppKit
import Vision
import CoreImage
import ServiceManagement
import UniformTypeIdentifiers

let SUPPORT = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CodexDog", isDirectory: true)

enum PoseKind: Int { case idle = 0, happy, dizzy }

// crop：在原照片里截取小狗所在区域（相对坐标，左上角为原点），避开地上的鞋子和纸屑
// erase：尾巴尖旁边的白色纸屑（和尾巴挨着，crop 切不开），抠图前把这块里的白色像素涂成地面色
struct Pose { let name: String; let file: String; let crop: CGRect; let erase: CGRect }
let POSES = [
    Pose(name: "idle",  file: "idle.heic",  crop: CGRect(x: 0.13, y: 0.15, width: 0.67, height: 0.61),
         erase: CGRect(x: 0.51, y: 0.16, width: 0.11, height: 0.10)),
    Pose(name: "happy", file: "happy.heic", crop: CGRect(x: 0.04, y: 0.16, width: 0.80, height: 0.66),
         erase: CGRect(x: 0.49, y: 0.19, width: 0.11, height: 0.10)),
    Pose(name: "dizzy", file: "dizzy.heic", crop: CGRect(x: 0.05, y: 0.19, width: 0.82, height: 0.52),
         erase: CGRect(x: 0.50, y: 0.18, width: 0.11, height: 0.10)),
]
// 视频 IMG_5966 里的素材：0.2–1.1 秒站起来作揖（photos/beg，追淀粉肠时也是这个动作），
// 0 秒那一帧的淀粉肠（photos/sausage.jpg）
let BEG_FPS = 15.0

// MARK: - 隐藏系统光标（后台 App 默认不能藏光标，这个私有开关很多光标工具都在用）

@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

func allowBackgroundCursorHiding() {
    let c = _CGSDefaultConnection()
    _ = CGSSetConnectionProperty(c, c, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

// MARK: - 图片处理

func loadCG(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    if maxPixel == 0 { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func savePNG(_ img: CGImage, _ url: URL) {
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

/// 把图片画进一块 RGBA 内存（第 0 行是图片顶部），改完像素再 makeImage
func rgbaContext(_ img: CGImage, flipX: Bool = false) -> CGContext? {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    if flipX { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx
}

/// 不透明像素的包围盒（像素坐标，左上角为原点）
func opaqueBounds(_ ctx: CGContext) -> CGRect {
    guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .null }
    var minX = ctx.width, minY = ctx.height, maxX = -1, maxY = -1
    for y in 0..<ctx.height { for x in 0..<ctx.width where px[(y * ctx.width + x) * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return maxX < 0 ? .null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// 把 rect（像素坐标，左上角为原点）里的白色纸屑涂成周围地面的平均色；小狗是黑的，不受影响
func erasePaper(_ img: CGImage, _ rect: CGRect) -> CGImage? {
    let w = img.width, h = img.height
    guard let ctx = rgbaContext(img), let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let box = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
    guard !box.isEmpty else { return img }
    let xs = Int(box.minX)..<Int(box.maxX), ys = Int(box.minY)..<Int(box.maxY)
    func luma(_ i: Int) -> Int { (Int(px[i]) * 3 + Int(px[i + 1]) * 6 + Int(px[i + 2])) / 10 }

    // 地面色：框里中等亮度像素的平均
    var sum = [0, 0, 0], n = 0
    for y in ys { for x in xs {
        let i = (y * w + x) * 4, l = luma(i)
        if l > 100 && l < 190 { sum[0] += Int(px[i]); sum[1] += Int(px[i + 1]); sum[2] += Int(px[i + 2]); n += 1 }
    } }
    guard n > 0 else { return img }
    let floor = sum.map { UInt8($0 / n) }
    for y in ys { for x in xs {
        let i = (y * w + x) * 4
        if luma(i) >= 190 { px[i] = floor[0]; px[i + 1] = floor[1]; px[i + 2] = floor[2] }
    } }
    return ctx.makeImage()
}

/// 用系统的主体识别抠图（和"照片"里长按抠图是同一个功能）
/// biggestOnly：只要最大的那块（视频帧里只要小狗）；否则保留大块主体（小狗 + 手），去掉纸屑之类的小东西
func liftSubject(_ img: CGImage, biggestOnly: Bool = false, cropToExtent: Bool = true) -> CGImage? {
    let req = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    do {
        try handler.perform([req])
        guard let obs = req.results?.first else { return nil }

        let mask = obs.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let bpr = CVPixelBufferGetBytesPerRow(mask)
        var counts = [Int](repeating: 0, count: 256)
        if let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<h { for x in 0..<w { counts[Int(base[y * bpr + x])] += 1 } }
        }
        CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        let all = Array(obs.allInstances)
        let biggest = all.map { counts[$0] }.max() ?? 0
        let keep = IndexSet(all.filter { biggestOnly ? counts[$0] == biggest : counts[$0] * 12 >= biggest })

        let buf = try obs.generateMaskedImage(ofInstances: keep.isEmpty ? obs.allInstances : keep,
                                              from: handler, croppedToInstancesExtent: cropToExtent)
        let ci = CIImage(cvPixelBuffer: buf)
        return CIContext().createCGImage(ci, from: ci.extent)
    } catch {
        NSLog("CodexDog 抠图失败: \(error)")
        return nil
    }
}

func makeSprites(resources: URL) -> [CGImage?] {
    try? FileManager.default.createDirectory(at: SUPPORT, withIntermediateDirectories: true)
    return POSES.map { (p: Pose) -> CGImage? in
        let cache = SUPPORT.appendingPathComponent(p.name + ".png")
        if let cached = loadCG(cache, maxPixel: 0) { return cached }
        guard let full = loadCG(resources.appendingPathComponent(p.file), maxPixel: 1600) else { return nil }
        let fw = CGFloat(full.width), fh = CGFloat(full.height)
        let r = CGRect(x: p.crop.minX * fw, y: p.crop.minY * fh,
                       width: p.crop.width * fw, height: p.crop.height * fh).integral
        let er = CGRect(x: p.erase.minX * fw, y: p.erase.minY * fh,
                        width: p.erase.width * fw, height: p.erase.height * fh).integral
        let cropped = full.cropping(to: r) ?? full
        let cleaned = erasePaper(cropped, er.offsetBy(dx: -r.minX, dy: -r.minY)) ?? cropped
        let out = liftSubject(cleaned) ?? cleaned
        savePNG(out, cache)
        return out
    }
}

/// 作揖动画帧：每帧只留小狗，去掉沾在毛上的叶子（小黑全身黑，鲜艳的亮色都不是它），
/// 再统一裁到所有帧的并集，播放时不会抖
func makeFrames(_ folder: String, resources: URL) -> [CGImage] {
    let dir = SUPPORT.appendingPathComponent(folder, isDirectory: true)
    let srcDir = resources.appendingPathComponent(folder, isDirectory: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: srcDir.path)) ?? [])
        .filter { $0.hasSuffix(".jpg") }.sorted()
    let cached = names.compactMap { loadCG(dir.appendingPathComponent($0.replacingOccurrences(of: ".jpg", with: ".png")), maxPixel: 0) }
    if !names.isEmpty && cached.count == names.count { return cached }

    var ctxs: [CGContext] = []
    var union = CGRect.null
    for n in names {
        guard let src = loadCG(srcDir.appendingPathComponent(n), maxPixel: 0),
              let lifted = liftSubject(src, biggestOnly: true, cropToExtent: false),
              let ctx = rgbaContext(lifted), let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { continue }
        // 叶子粘在头顶边缘：头顶这一条里发亮的也去掉（眼睛在更下面，不会误伤眼睛的反光）
        let body = opaqueBounds(ctx)
        let headTop = body.isNull ? 0 : Int(body.minY + body.height * 0.08)
        for i in stride(from: 0, to: ctx.width * ctx.height * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let a = max(Int(px[i + 3]), 1), luma = (r * 3 + g * 6 + b) * 255 / 10 / a
            let leaf = (g > r + 20 && g > b + 10) || (r > 90 && r > b + 45)
                || (i / 4 / ctx.width < headTop && luma > 125)
            if leaf { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0 }
        }
        union = union.union(opaqueBounds(ctx))
        ctxs.append(ctx)
    }
    guard !union.isNull else { return [] }
    let outs = ctxs.compactMap { $0.makeImage()?.cropping(to: union) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (n, out) in zip(names, outs) {
        savePNG(out, dir.appendingPathComponent(n.replacingOccurrences(of: ".jpg", with: ".png")))
    }
    return outs
}

/// 淀粉肠光标：抠出来后左右翻转，让肠头朝左上，像箭头一样
func makeSausage(resources: URL) -> CGImage? {
    let cache = SUPPORT.appendingPathComponent("sausage.png")
    if let cached = loadCG(cache, maxPixel: 0) { return cached }
    guard let src = loadCG(resources.appendingPathComponent("sausage.jpg"), maxPixel: 0),
          let lifted = liftSubject(src, biggestOnly: true),
          let ctx = rgbaContext(lifted, flipX: true) else { return nil }
    let box = opaqueBounds(ctx)
    guard !box.isNull, let out = ctx.makeImage()?.cropping(to: box) else { return nil }
    savePNG(out, cache)
    return out
}

/// 肠头（最上面一行不透明像素的中点），作为光标的点击点；返回相对坐标，左上角为原点
func sausageTip(_ img: CGImage) -> CGPoint {
    guard let ctx = rgbaContext(img), let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .zero }
    for y in 0..<ctx.height {
        var xs: [Int] = []
        for x in 0..<ctx.width where px[(y * ctx.width + x) * 4 + 3] > 128 { xs.append(x) }
        if !xs.isEmpty {
            return CGPoint(x: CGFloat(xs[xs.count / 2]) / CGFloat(ctx.width), y: CGFloat(y) / CGFloat(ctx.height))
        }
    }
    return .zero
}

// MARK: - 晃动检测：鼠标在屏幕右下角来回晃

final class ShakeDetector {
    let corner: CGFloat = 300          // 右下角多大范围算数
    let minSwing: CGFloat = 28         // 一次来回至少多远
    let window: TimeInterval = 1.2     // 多长时间内
    let needed = 4                     // 掉头几次
    private var dir = [0, 0]
    private var extreme: [CGFloat]? = nil
    private var turns: [TimeInterval] = []

    func inCorner(_ p: NSPoint) -> NSScreen? {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return nil }
        let f = s.frame
        return p.x > f.maxX - corner && p.y < f.minY + corner ? s : nil
    }

    func reset() { dir = [0, 0]; extreme = nil; turns = [] }

    /// 每个方向（横、竖）记住当前朝哪走、走到的最远点；反方向走回超过 minSwing 就算掉头一次
    /// 返回晃动发生的屏幕
    func feed(_ p: NSPoint, at t: TimeInterval) -> NSScreen? {
        guard let screen = inCorner(p) else { reset(); return nil }
        guard var ext = extreme else { extreme = [p.x, p.y]; return nil }
        for (axis, v) in [p.x, p.y].enumerated() {
            let d = v - ext[axis]
            if dir[axis] == 0 {
                if abs(d) > minSwing / 2 { dir[axis] = d > 0 ? 1 : -1; ext[axis] = v }
            } else if (d > 0 ? 1 : -1) == dir[axis] {
                ext[axis] = v
            } else if abs(d) > minSwing {
                turns.append(t)
                dir[axis] = -dir[axis]
                ext[axis] = v
            }
        }
        extreme = ext
        turns.removeAll { t - $0 > window }
        if turns.count >= needed { reset(); return screen }
        return nil
    }
}

// MARK: - 视图（处理点击、拖动、右键、悬停）

final class DogView: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var downPoint = NSPoint.zero
    private var winOrigin = NSPoint.zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downPoint = NSEvent.mouseLocation
        winOrigin = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        if !dragging && hypot(dx, dy) < 4 { return }
        dragging = true
        window?.setFrameOrigin(NSPoint(x: winOrigin.x + dx, y: winOrigin.y + dy))
    }
    override func mouseUp(with e: NSEvent) {
        if !dragging { onClick?() }
    }
    override func rightMouseDown(with e: NSEvent) { onMenu?(e) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

// MARK: - 淀粉肠光标：一个跟着鼠标走、不接收点击的小窗口，同时把系统光标藏起来

final class SausageCursor {
    let H: CGFloat = 64
    private var panel: NSPanel?
    private let layer = CALayer()
    private var tip = CGPoint.zero
    private var size = NSSize.zero
    private var cursorHidden = false
    var isShown: Bool { panel?.isVisible == true }

    func setImage(_ img: CGImage) {
        size = NSSize(width: H * CGFloat(img.width) / CGFloat(img.height), height: H)
        let t = sausageTip(img)
        tip = CGPoint(x: t.x * size.width, y: (1 - t.y) * size.height)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        layer.frame = v.bounds
        layer.contents = img
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = p.backingScaleFactor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 1, height: -2)
        v.layer?.addSublayer(layer)
        p.contentView = v
        panel = p
    }

    func show() {
        guard let p = panel, !p.isVisible else { return }
        follow(NSEvent.mouseLocation)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        p.orderFrontRegardless()
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.2, 1.25, 1]
        pop.duration = 0.3
        layer.add(pop, forKey: "pop")
        if !cursorHidden { CGDisplayHideCursor(CGMainDisplayID()); cursorHidden = true }
    }

    func follow(_ m: NSPoint) {
        panel?.setFrameOrigin(NSPoint(x: m.x - tip.x, y: m.y - tip.y))
    }

    /// eaten：被吃掉（缩小消失）；否则直接收起
    func hide(eaten: Bool) {
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()); cursorHidden = false }
        guard let p = panel, p.isVisible else { return }
        guard eaten else { p.orderOut(nil); return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { p.orderOut(nil) }
        layer.transform = CATransform3DMakeScale(0.05, 0.05, 1)
        layer.opacity = 0
        CATransaction.commit()
    }
}

// MARK: - 桌宠

final class Pet: NSObject {
    let W: CGFloat = 230, H: CGFloat = 280, dogH: CGFloat = 200
    let begTime: TimeInterval = 1.0       // 刚出来先作揖一会儿，再开始追
    let chaseTimeout: TimeInterval = 15   // 一直追不上，就一个飞扑抢走
    let runSpeed: CGFloat = 650           // 追淀粉肠的速度（点/秒），鼠标甩快了它就追不上
    let idleHide: TimeInterval = 25       // 鼠标多久没来就跑回角落躲起来
    var panel: NSPanel!
    var view: DogView!
    let dog = CALayer()
    let bubble = CALayer()
    let text = CATextLayer()
    var sprites: [CGImage?] = [nil, nil, nil]
    var begFrames: [CGImage] = []
    let sausage = SausageCursor()
    let shake = ShakeDetector()
    // begging：刚钻出来作揖；chasing：追淀粉肠；returning：跑回角落准备躲起来
    enum St { case loading, hidden, begging, chasing, idle, returning, cleaning, done }
    var st = St.loading
    var hovering = false
    var hideBubble: DispatchWorkItem?
    var begStarted = Date.distantPast
    var lastTick = Date()
    var running = false
    var homeScreen: NSScreen?
    var lastSeen = Date()                 // 鼠标最后一次在小狗身上（或刚出来）的时间
    var fedAt = Date.distantPast
    var menuOpen = false
    var ticker: Timer?
    let resources = Bundle.main.resourceURL!

    func start() {
        allowBackgroundCursorHiding()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        view = DogView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let root = CALayer()
        root.masksToBounds = true          // 小狗从窗口底边"钻"出来
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view

        let scale = panel.backingScaleFactor
        dog.anchorPoint = CGPoint(x: 0.5, y: 0)
        dog.position = CGPoint(x: W / 2, y: 4)
        dog.contentsGravity = .resizeAspect
        dog.contentsScale = scale
        dog.shadowColor = NSColor.black.cgColor
        dog.shadowOpacity = 0.3
        dog.shadowRadius = 6
        dog.shadowOffset = CGSize(width: 0, height: -3)
        root.addSublayer(dog)

        bubble.frame = CGRect(x: 8, y: dogH + 10, width: W - 16, height: 58)
        bubble.backgroundColor = NSColor(white: 1, alpha: 0.96).cgColor
        bubble.cornerRadius = 16
        bubble.shadowColor = NSColor.black.cgColor
        bubble.shadowOpacity = 0.18
        bubble.shadowRadius = 8
        bubble.shadowOffset = CGSize(width: 0, height: -2)
        bubble.opacity = 0
        text.frame = bubble.bounds.insetBy(dx: 10, dy: 10)
        text.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        text.fontSize = 14
        text.foregroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = scale
        bubble.addSublayer(text)
        root.addSublayer(bubble)

        view.onClick = { [weak self] in self?.clicked() }
        view.onMenu = { [weak self] e in self?.showMenu(e) }
        view.onHover = { [weak self] inside in self?.hover(inside) }

        // 第一次（刚装好/重新抠图）先露个脸打个招呼，平时启动就直接躲着
        let firstRun = !FileManager.default.fileExists(atPath: SUPPORT.appendingPathComponent("beg").path)
        if firstRun {
            placeInCorner(NSScreen.main)
            panel.orderFrontRegardless()
            say("第一次见面，正在打扮自己…", hold: true)
        }
        loadSprites { [weak self] in
            guard let self else { return }
            if firstRun {
                self.st = .idle
                self.lastSeen = Date()
                self.setPose(.idle)
                self.breathe(true)
                self.say("汪！我平时躲起来，在屏幕右下角晃晃鼠标，我就出来～", seconds: 6)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
                    if self.st == .idle && !self.hovering { self.hideDog() }
                }
            } else {
                self.st = .hidden
            }
        }

        ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    func loadSprites(_ done: @escaping () -> Void) {
        let res = resources
        DispatchQueue.global(qos: .userInitiated).async {
            let s = makeSprites(resources: res)
            let beg = makeFrames("beg", resources: res)
            let sau = makeSausage(resources: res)
            DispatchQueue.main.async {
                self.sprites = s
                self.begFrames = beg
                if let sau { self.sausage.setImage(sau) }
                done()
            }
        }
    }

    // MARK: 每帧：检测晃动、淀粉肠跟着鼠标、小黑追淀粉肠、没人理就跑回去躲起来

    func tick() {
        let m = NSEvent.mouseLocation
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(lastTick), 0.05))
        lastTick = now
        switch st {
        case .hidden:
            if let screen = shake.feed(m, at: now.timeIntervalSinceReferenceDate) { summon(on: screen) }
        case .begging:
            sausage.follow(m)
            if now.timeIntervalSince(begStarted) > begTime {
                st = .chasing
                begStarted = now
                hideBubble?.cancel()
                bubble.opacity = 0
            }
        case .chasing:
            sausage.follow(m)
            // 让小狗身体中心对准淀粉肠，追到（鼠标停下来让它够着）就吃
            let target = clamped(NSPoint(x: m.x - W / 2, y: m.y - 4 - dog.bounds.height / 2))
            let o = panel.frame.origin
            if hypot(target.x - o.x, target.y - o.y) < 25 && now.timeIntervalSince(begStarted) > 0.8 {
                eat()
            } else if now.timeIntervalSince(begStarted) > chaseTimeout {
                eat(snatched: true)
            } else {
                runToward(target, dt: dt)
            }
        case .returning:
            if runToward(cornerOrigin(homeScreen), dt: dt) { st = .idle; hideDog() }
        case .idle:
            if hovering || menuOpen { lastSeen = now }
            else if now.timeIntervalSince(lastSeen) > idleHide { hideDog() }
        default:
            break
        }
    }

    /// 朝 target（窗口原点）跑一步；到了返回 true
    @discardableResult
    func runToward(_ target: NSPoint, dt: CGFloat) -> Bool {
        let o = panel.frame.origin
        let dx = target.x - o.x, dy = target.y - o.y
        let dist = hypot(dx, dy)
        if dist < 3 { setRunning(false); return true }
        let step = min(dist, runSpeed * dt)
        panel.setFrameOrigin(NSPoint(x: o.x + dx / dist * step, y: o.y + dy / dist * step))
        if dist > 12 { setRunning(true, left: dx < 0) }
        return false
    }

    /// 别让小狗跑出屏幕（脚不低于屏幕底边，身子不出左右边）
    func clamped(_ o: NSPoint) -> NSPoint {
        let scr = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let f = scr?.frame else { return o }
        let half = dog.bounds.width / 2
        return NSPoint(x: min(max(o.x, f.minX - W / 2 + half), f.maxX - W / 2 - half),
                       y: min(max(o.y, f.minY), f.maxY - dog.bounds.height - 4))
    }

    func dogScreenRect() -> NSRect {
        let f = dog.frame
        return NSRect(x: panel.frame.minX + f.minX, y: panel.frame.minY + f.minY, width: f.width, height: f.height)
    }

    func cornerOrigin(_ screen: NSScreen?) -> NSPoint {
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - W - 12, y: vf.minY)
    }

    func placeInCorner(_ screen: NSScreen?) {
        homeScreen = screen
        panel.setFrameOrigin(cornerOrigin(screen))
    }

    // MARK: 出来 / 追 / 吃 / 躲回去

    func summon(on screen: NSScreen?) {
        guard st == .hidden, !begFrames.isEmpty else { return }
        st = .begging
        begStarted = Date()
        hovering = false
        // 从淀粉肠左边一点的屏幕底边钻出来，看见淀粉肠再跑过去
        homeScreen = screen
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let m = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: max(vf.minX, min(m.x - W / 2 - 380, vf.maxX - W)), y: vf.minY))
        panel.orderFrontRegardless()
        sausage.show()
        playBeg()
        slide(in: true)
        say("汪！淀粉肠！", hold: true)
    }

    /// 追的时候和视频里一样站起来作揖，一蹦一蹦地跟着走；
    /// 伸出来的那只前爪在图的左边，往右走时左右翻转，让爪子总朝着淀粉肠
    func setRunning(_ on: Bool, left: Bool = false) {
        guard !begFrames.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dog.transform = on && !left ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
        guard on != running else { return }
        running = on
        if on {
            if dog.animation(forKey: "beg") == nil { playBeg() }
            let hop = CAKeyframeAnimation(keyPath: "position.y")
            hop.values = [4, 16, 4]
            hop.duration = 0.3
            hop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hop.repeatCount = .infinity
            dog.add(hop, forKey: "hop")
        } else {
            dog.removeAnimation(forKey: "hop")
        }
    }

    func eat(snatched: Bool = false) {
        guard st == .begging || st == .chasing else { return }
        sausage.hide(eaten: true)
        setRunning(false)
        dog.removeAnimation(forKey: "beg")
        st = .idle
        fedAt = Date()
        lastSeen = Date()
        setPose(.happy)
        bounce()
        say(snatched ? "嗷呜！抢到啦～ 点我清理旧图片" : "嗷呜～好吃！点我清理旧图片", seconds: 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard self.st == .idle else { return }
            self.setPose(self.hovering ? .happy : .idle)
            self.breathe(true)
        }
    }

    func hideDog() {
        guard st == .idle || st == .begging || st == .chasing else { return }
        sausage.hide(eaten: false)
        // 不在角落就先跑回去，到了再钻下去
        let home = cornerOrigin(homeScreen)
        if hypot(panel.frame.minX - home.x, panel.frame.minY - home.y) > 3 {
            hideBubble?.cancel()
            bubble.opacity = 0
            breathe(false)
            st = .returning
            return
        }
        setRunning(false)
        st = .hidden
        shake.reset()
        hideBubble?.cancel()
        bubble.opacity = 0
        slide(in: false) { [weak self] in
            guard let self, self.st == .hidden else { return }
            self.dog.removeAllAnimations()
            self.panel.orderOut(nil)
        }
    }

    func slide(in entering: Bool, done: (() -> Void)? = nil) {
        let hidden = -dog.bounds.height - 10
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = entering ? hidden : 4
        a.toValue = entering ? 4 : hidden
        a.duration = entering ? 0.45 : 0.35
        a.timingFunction = CAMediaTimingFunction(name: entering ? .easeOut : .easeIn)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = entering
        dog.add(a, forKey: "slide")
        CATransaction.commit()
    }

    // MARK: 外观

    func show(_ cg: CGImage) {
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = min((W - 10) / iw, (dogH - 6) / ih)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dog.bounds = CGRect(x: 0, y: 0, width: iw * s, height: ih * s)
        dog.contents = cg
        CATransaction.commit()
    }

    func setPose(_ k: PoseKind) {
        guard let cg = sprites[k.rawValue] ?? sprites[0] else { return }
        dog.removeAnimation(forKey: "beg")
        setRunning(false)
        show(cg)
    }

    /// 视频里的作揖动作，来回播放
    func playBeg() {
        breathe(false)
        wobble(false)
        show(begFrames[0])
        let seq = begFrames + begFrames.reversed().dropFirst().dropLast()
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = seq
        a.calculationMode = .discrete
        a.duration = Double(seq.count) / BEG_FPS
        a.repeatCount = .infinity
        dog.add(a, forKey: "beg")
    }

    func breathe(_ on: Bool) {
        dog.removeAnimation(forKey: "breathe")
        guard on else { return }
        let a = CABasicAnimation(keyPath: "transform.scale.y")
        a.fromValue = 1.0
        a.toValue = 1.03
        a.duration = 1.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dog.add(a, forKey: "breathe")
    }

    func wobble(_ on: Bool) {
        dog.removeAnimation(forKey: "wobble")
        guard on else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = -0.07
        a.toValue = 0.07
        a.duration = 0.12
        a.autoreverses = true
        a.repeatCount = .infinity
        dog.add(a, forKey: "wobble")
    }

    func bounce() {
        let a = CAKeyframeAnimation(keyPath: "position.y")
        a.values = [4, 34, 4, 18, 4]
        a.keyTimes = [0, 0.3, 0.55, 0.78, 1]
        a.duration = 0.75
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dog.add(a, forKey: "bounce")
    }

    func say(_ msg: String, seconds: Double = 0, hold: Bool = false) {
        hideBubble?.cancel()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        text.string = msg
        bubble.opacity = 1
        CATransaction.commit()
        guard !hold else { return }
        let work = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            self?.bubble.opacity = 0
            CATransaction.commit()
        }
        hideBubble = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds > 0 ? seconds : 3), execute: work)
    }

    func hover(_ inside: Bool) {
        hovering = inside
        if inside { lastSeen = Date() }
        guard st == .idle else { return }
        setPose(inside ? .happy : .idle)
    }

    // MARK: 清理

    func clicked() {
        // 刚吃完那一下点击多半是"喂食"的顺手一点，不当成清理
        guard Date().timeIntervalSince(fedAt) > 1.5 else { return }
        clean()
    }

    func clean() {
        guard st == .idle || st == .done else { return }
        st = .cleaning
        breathe(false)
        setPose(.dizzy)
        wobble(true)
        say("呜呜，正在清理…", hold: true)

        let started = Date()
        let reopen = NSWorkspace.shared.runningApplications
            .filter { ["Codex", "ChatGPT"].contains($0.localizedName ?? "") }
            .compactMap { $0.bundleURL }
        let script = resources.appendingPathComponent("clean_images.py").path

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script]
            var env = ProcessInfo.processInfo.environment
            env["PYTHONIOENCODING"] = "utf-8"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var out = ""
            var code: Int32 = -1
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(decoding: data, as: UTF8.self)
                code = p.terminationStatus
            } catch {
                out = "运行失败：\(error.localizedDescription)"
            }
            let wait = max(0, 1.6 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.finish(out: out, code: code, reopen: reopen)
            }
        }
    }

    func finish(out: String, code: Int32, reopen: [URL]) {
        wobble(false)
        st = .done
        if code == 0, let r = parse(out) {
            let (n, mb) = r
            setPose(.happy)
            bounce()
            say(n == 0 ? "已经很干净啦，没有旧图片～" : "清掉 \(n) 张图，瘦身 \(mb) MB！", seconds: 4)
        } else {
            setPose(.idle)
            let last = out.split(separator: "\n").last.map(String.init) ?? "出错了"
            say("清理失败：\(last)", seconds: 6)
        }
        // 清理脚本会退出 Codex / ChatGPT，清理完帮你重新打开
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        for url in reopen { NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in } }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard self.st == .done else { return }
            self.st = .idle
            self.lastSeen = Date()
            self.setPose(self.hovering ? .happy : .idle)
            self.breathe(true)
        }
    }

    func parse(_ out: String) -> (Int, String)? {
        guard let re = try? NSRegularExpression(pattern: "清理 (\\d+) 张图片.*释放 ([\\d.]+) MB"),
              let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r1 = Range(m.range(at: 1), in: out), let r2 = Range(m.range(at: 2), in: out)
        else { return nil }
        return (Int(out[r1]) ?? 0, String(out[r2]))
    }

    // MARK: 右键菜单

    func showMenu(_ e: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "立即清理", action: #selector(menuClean), keyEquivalent: "").target = self
        menu.addItem(withTitle: "躲起来", action: #selector(menuHide), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "重新抠图", action: #selector(recut), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "").target = self
        menuOpen = true
        NSMenu.popUpContextMenu(menu, with: e, for: view)
        menuOpen = false
        lastSeen = Date()
    }

    @objc func menuClean() { clean() }
    @objc func menuHide() { hideDog() }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister(); say("已关闭开机启动") }
            else { try s.register(); say("以后开机我就会躲在右下角～") }
        } catch {
            say("设置失败：\(error.localizedDescription)", seconds: 5)
        }
    }

    @objc func recut() {
        guard st == .idle || st == .done else { return }
        try? FileManager.default.removeItem(at: SUPPORT)
        st = .loading
        say("重新打扮中…", hold: true)
        loadSprites { [weak self] in
            guard let self else { return }
            self.st = .idle
            self.lastSeen = Date()
            self.setPose(.idle)
            self.say("好啦！", seconds: 2)
        }
    }

    /// 在 Finder / 启动台里再次打开 App 时，直接把小狗叫出来
    func reopen() {
        guard st == .hidden else { return }
        summon(on: NSScreen.main)
    }

    @objc func quit() {
        sausage.hide(eaten: false)
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let pet = Pet()
    func applicationDidFinishLaunching(_ n: Notification) { pet.start() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pet.reopen()
        return false
    }
    func applicationWillTerminate(_ n: Notification) { pet.sausage.hide(eaten: false) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
