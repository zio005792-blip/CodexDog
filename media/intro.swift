// 小黑介绍视频：逐帧画出来，再用 AVAssetWriter 编成 MP4
// 用法：swiftc -O intro.swift -o intro && ./intro out.mp4
//       ./intro --still 5.0,12.5 outdir   只导出这几秒的 PNG 预览
// 素材来自 CodexDog 第一次启动时抠好的图：~/Library/Application Support/CodexDog
import AppKit
import AVFoundation
import CoreText

let W = 1920.0, H = 1080.0, FPS = 30.0, DUR = 38.0
let SUP = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexDog")

// MARK: - 素材

func load(_ p: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(SUP.appendingPathComponent(p) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func frames(_ dir: String) -> [CGImage] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: SUP.appendingPathComponent(dir).path)) ?? []
    return names.filter { $0.hasSuffix(".png") }.sorted().map { load(dir + "/" + $0) }
}
// idle/happy/dizzy 三张照片里带着摸它的手，视频里只用没有手的素材
let SLEEP = load("sleep.png"), BELLY = load("belly.png"), SAUSAGE = load("sausage.png")
let BEG = frames("beg"), STAND = frames("stand"), LOOK = frames("look")

// MARK: - 数学

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func backOut(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
func pingpong(_ f: [CGImage], _ t: Double, fps: Double) -> CGImage {
    let n = f.count
    guard n > 1 else { return f[0] }
    let period = 2 * n - 2
    let k = Int(max(0, t) * fps) % period
    return f[k < n ? k : period - k]
}

// MARK: - 画图（左上角为原点，y 向下）

var ctx: CGContext!

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: a)
}
func lerpColor(_ a: UInt32, _ b: UInt32, _ x: Double) -> CGColor {
    func c(_ h: UInt32, _ s: UInt32) -> Double { Double((h >> s) & 0xff) / 255 }
    return CGColor(red: lerp(c(a, 16), c(b, 16), x), green: lerp(c(a, 8), c(b, 8), x),
                   blue: lerp(c(a, 0), c(b, 0), x), alpha: 1)
}

func fill(_ r: CGRect, _ c: CGColor, radius: Double = 0, shadow: Double = 0) {
    ctx.saveGState()
    if shadow > 0 { ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: shadow, color: rgb(0x000000, 0.18)) }
    ctx.setFillColor(c)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

func gradient(_ top: UInt32, _ bottom: UInt32) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
}

/// 以脚底中点 (cx, bottom) 为锚点画小狗
func dog(_ img: CGImage, cx: Double, bottom: Double, height: Double, alpha: Double = 1,
         flip: Bool = false, rot: Double = 0, sy: Double = 1, shadow: Bool = true) {
    let w = height * Double(img.width) / Double(img.height)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: bottom)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: flip ? -1 : 1, y: -sy)
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x000000, 0.28)) }
    ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: height))
    ctx.restoreGState()
}

@discardableResult
func text(_ s: String, _ x: Double, _ y: Double, size: Double, weight: String = "Semibold",
          color: CGColor = rgb(0x1c1c1e), alpha: Double = 1, align: Double = 0.5, mono: Bool = false) -> Double {
    guard alpha > 0.001 else { return 0 }
    let font = CTFontCreateWithName((mono ? "Menlo-Bold" : "PingFangSC-" + weight) as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    var asc: CGFloat = 0, desc: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &asc, &desc, nil)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x - w * align, y: y + (asc - desc) / 2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return w
}

func textWidth(_ s: String, size: Double) -> Double {
    let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
}

/// 对话气泡，尖角朝下指向 (cx, bottom)
func bubble(_ s: String, cx: Double, bottom: Double, alpha: Double, size: Double = 32) {
    guard alpha > 0.001 else { return }
    let w = textWidth(s, size: size) + size * 1.6, h = size * 2.1
    let r = CGRect(x: cx - w / 2, y: bottom - h - 16, width: w, height: h)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: bottom)
    let s0 = 0.85 + 0.15 * alpha
    ctx.scaleBy(x: s0, y: s0)
    ctx.translateBy(x: -cx, y: -bottom)
    fill(r, rgb(0xffffff), radius: h / 2, shadow: 14)
    ctx.setFillColor(rgb(0xffffff))
    ctx.move(to: CGPoint(x: cx - 14, y: r.maxY - 2))
    ctx.addLine(to: CGPoint(x: cx, y: bottom))
    ctx.addLine(to: CGPoint(x: cx + 14, y: r.maxY - 2))
    ctx.fillPath()
    text(s, cx, r.midY, size: size)
    ctx.restoreGState()
}

func arrow(_ x: Double, _ y: Double, scale: Double = 1.6, alpha: Double = 1) {
    guard scale > 0.01 else { return }
    let pts: [(Double, Double)] = [(0, 0), (0, 34), (9, 26), (15, 40), (21, 37), (15, 24), (27, 24)]
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: rgb(0x000000, 0.35))
    ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath()
    ctx.setFillColor(rgb(0x111111))
    ctx.setStrokeColor(rgb(0xffffff))
    ctx.setLineWidth(2)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

func sausage(_ x: Double, _ y: Double, height: Double = 150, scale: Double = 1, rot: Double = 0) {
    guard scale > 0.01 else { return }
    let h = height * scale, w = h * Double(SAUSAGE.width) / Double(SAUSAGE.height)
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: rgb(0x000000, 0.3))
    ctx.draw(SAUSAGE, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}

/// 一张"截图"小卡片
func card(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, hue: Int, alpha: Double = 1, scale: Double = 1) {
    guard alpha > 0.001, scale > 0.01 else { return }
    let colors: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5]
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: scale, y: scale)
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    fill(r, rgb(0xffffff), radius: 10, shadow: 8)
    fill(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.16), rgb(0xe9e9ee), radius: 10)
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.27, width: w * 0.5, height: h * 0.4), rgb(colors[hue % 6]), radius: 6)
    for i in 0..<3 {
        fill(CGRect(x: r.minX + w * 0.64, y: r.minY + h * (0.3 + Double(i) * 0.14), width: w * 0.26, height: h * 0.06), rgb(0xd5d5dc), radius: 3)
    }
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.76, width: w * 0.82, height: h * 0.07), rgb(0xd5d5dc), radius: 3)
    ctx.restoreGState()
}

func quotaBar(x: Double, y: Double, w: Double, frac: Double, label: String) {
    text(label, x, y - 36, size: 30, weight: "Medium", color: rgb(0x55555c), align: 0)
    fill(CGRect(x: x, y: y, width: w, height: 34), rgb(0xdedbd2), radius: 17)
    let c = frac > 0.5 ? lerpColor(0xf0a04b, 0x3fb26b, (frac - 0.5) * 2) : lerpColor(0xe5484d, 0xf0a04b, frac * 2)
    fill(CGRect(x: x, y: y, width: max(34, w * frac), height: 34), c, radius: 17)
    text("\(Int((frac * 100).rounded()))%", x + w + 20, y + 17, size: 30, color: rgb(0x55555c), align: 0)
}

func caption(_ s: String, _ t: Double, from: Double, y: Double = 130, size: Double = 60,
             color: CGColor = rgb(0x1c1c1e), until: Double = 1e9) {
    let a = prog(t, from, from + 0.4) * (1 - prog(t, until - 0.3, until))
    let dy = (1 - easeOut(prog(t, from, from + 0.4))) * 24
    text(s, W / 2, y + dy, size: size, color: color, alpha: a)
}

// MARK: - 桌面

func desktop(_ t: Double) {
    gradient(0x3a6ea5, 0x8fb3d9)
    // 几道柔和的光
    ctx.saveGState()
    ctx.setFillColor(rgb(0xffffff, 0.08))
    ctx.fillEllipse(in: CGRect(x: -300, y: 520, width: 1400, height: 700))
    ctx.fillEllipse(in: CGRect(x: 1100, y: -200, width: 1100, height: 600))
    ctx.restoreGState()
    fill(CGRect(x: 0, y: 0, width: W, height: 36), rgb(0xffffff, 0.28))
    text("10:24", W - 30, 18, size: 22, weight: "Medium", color: rgb(0x1c1c1e), align: 1)
    let dock = CGRect(x: 600, y: H - 96, width: 720, height: 84)
    fill(dock, rgb(0xffffff, 0.32), radius: 24)
    let icons: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5, 0x1c1c1e, 0xf5c542, 0xff7a59]
    for (i, c) in icons.enumerated() {
        fill(CGRect(x: dock.minX + 22 + Double(i) * 76, y: dock.minY + 12, width: 60, height: 60), rgb(c), radius: 14)
    }
}

// MARK: - 追淀粉肠（逐帧积分，任何时刻都能直接算出来）

let chaseStart = 15.0, chaseStop = 19.15
let dogHome = (x: 1420.0, y: H - 20)
func sausagePos(_ t: Double) -> (Double, Double) {
    let u = min(t, chaseStop) - chaseStart
    let px = 960 + 620 * sin(u * 1.05 - 0.4), py = 560 + 170 * sin(u * 1.9 + 0.6)
    let b = easeInOut(prog(t, chaseStart, chaseStart + 0.9))
    return (lerp(1700, px, b), lerp(860, py, b))
}
func chaseState(_ t: Double) -> (x: Double, y: Double, left: Bool, moving: Bool) {
    var x = dogHome.x, y = dogHome.y, left = true, moving = false
    var tt = chaseStart
    while tt < t {
        let (sx, sy) = sausagePos(tt)
        // 跟在淀粉肠后下方追，别把它挡住
        let tx = sx + (left ? 150 : -150), ty = sy + 260
        let dx = tx - x, dy = ty - y, d = hypot(dx, dy)
        let step = min(d, 470.0 / FPS)
        moving = d > 6
        if d > 1 { x += dx / d * step; y += dy / d * step; if abs(dx) > 4 { left = dx < 0 } }
        tt += 1 / FPS
    }
    return (x, y, left, moving)
}

// MARK: - 分镜

func scene1(_ t: Double) {
    gradient(0x0f1724, 0x1d2b40)
    let rise = backOut(prog(t, 0.6, 1.5))
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: lerp(H + 40, 760, rise), height: 420)
    text("小黑", W / 2, 860, size: 120, color: rgb(0xffffff), alpha: prog(t, 0.3, 0.9))
    text("CodexDog · 给 Codex 省流量的桌宠", W / 2, 965, size: 44, weight: "Medium",
         color: rgb(0xb8c4d6), alpha: prog(t, 1.1, 1.7))
}

func scene2(_ t: Double) {
    gradient(0xf6f2ea, 0xece6da)
    caption("在 Codex 里贴过的截图", t, from: 3.6, y: 120)
    caption("每发一句话，都会被重新上传一遍", t, from: 4.2, y: 205, size: 46, color: rgb(0xd0453b))

    // 聊天窗口
    let win = CGRect(x: 170, y: 290, width: 700, height: 640)
    fill(win, rgb(0xffffff), radius: 28, shadow: 22)
    for i in 0..<5 {
        let right = i % 2 == 1
        let w = [420.0, 300, 460, 260, 380][i]
        fill(CGRect(x: right ? win.maxX - 40 - w : win.minX + 40, y: win.minY + 40 + Double(i) * 92, width: w, height: 62),
             rgb(right ? 0xdbe8ff : 0xf0f0f3), radius: 20)
    }
    let input = CGRect(x: win.minX + 30, y: win.maxY - 100, width: win.width - 60, height: 70)
    fill(input, rgb(0xf3f3f6), radius: 35)
    text("帮我看看这个报错…", input.minX + 30, input.midY, size: 28, weight: "Regular", color: rgb(0x9a9aa2), align: 0)

    let sends = (0..<6).map { 4.7 + Double($0) * 0.85 }
    var pulse = 0.0
    for s in sends where t >= s && t < s + 0.3 { pulse = 1 - (t - s) / 0.3 }
    let btn = CGPoint(x: input.maxX - 40, y: input.midY)
    let br = 26 + pulse * 6
    fill(CGRect(x: btn.x - br, y: btn.y - br, width: br * 2, height: br * 2), rgb(0x1c1c1e), radius: br)
    text("↑", btn.x, btn.y, size: 30, color: rgb(0xffffff))

    // 云
    let cloud = CGPoint(x: 1460, y: 420)
    ctx.setFillColor(rgb(0xc9d6ea))
    for (dx, dy, r) in [(-90.0, 20.0, 70.0), (0, -20, 95), (95, 20, 70), (0, 40, 80)] {
        ctx.fillEllipse(in: CGRect(x: cloud.x + dx - r, y: cloud.y + dy - r, width: r * 2, height: r * 2))
    }
    text("↑", cloud.x, cloud.y + 10, size: 90, color: rgb(0xffffff))

    // 飞上去的截图
    var arrived = 0
    for (k, s) in sends.enumerated() {
        for j in 0..<6 {
            let st = s + 0.05 + Double(j) * 0.07
            let p = prog(t, st, st + 0.75)
            if p >= 1 { arrived += 1; continue }
            guard p > 0 else { continue }
            let e = easeInOut(p)
            let x0 = win.midX - 120 + Double(j % 3) * 120, y0 = win.minY + 140 + Double(j / 3) * 120
            let cx = lerp(x0, cloud.x, e), cy = lerp(y0, cloud.y, e) - sin(e * .pi) * 160
            card(cx, cy, 130, 96, hue: k + j, alpha: 1 - prog(p, 0.85, 1), scale: lerp(1, 0.35, e))
        }
    }
    let mb = Double(arrived) * 8.8
    text(String(format: "已上传 %.0f MB", mb), cloud.x, 590, size: 64, color: rgb(0xd0453b), alpha: prog(t, 4.6, 5.0))
    quotaBar(x: 1150, y: 730, w: 560, frac: 1 - 0.82 * mb / (36 * 8.8), label: "VPN / 代理剩余额度")
    caption("流量和 VPN 额度，就这样被悄悄烧光", t, from: 8.4, y: 990, size: 42, color: rgb(0x55555c))
}

func scene3(_ t: Double) {
    desktop(t)
    caption("在屏幕右下角，来回晃晃鼠标", t, from: 10.2, y: 150, color: rgb(0xffffff), until: 12.5)
    caption("淀粉肠！小黑钻出来了", t, from: 12.6, y: 150, color: rgb(0xffffff))

    let base = (x: 1700.0, y: 860.0)
    let inP = easeOut(prog(t, 10.1, 10.6))
    let shakeT = t - 10.6
    let amp = t > 10.6 && t < 12.0 ? 95.0 * min(1, shakeT / 0.15) : 0
    func cx(_ tt: Double) -> Double {
        let a = tt > 10.6 && tt < 12.0 ? 95.0 * min(1, (tt - 10.6) / 0.15) : 0
        return lerp(1250, base.x, inP) + sin((tt - 10.6) * 2 * .pi * 3.2) * a
    }
    let cy = lerp(560, base.y, inP)
    if amp > 0 {
        for k in 1...5 { arrow(cx(t - Double(k) * 0.025), cy, alpha: 0.18 * Double(6 - k) / 5) }
    }
    let pop = prog(t, 12.0, 12.25)
    arrow(cx(t), cy, scale: 1.6 * (1 - pop))
    if t >= 12.0 { sausage(base.x, base.y + 20, scale: backOut(prog(t, 12.05, 12.4)), rot: sin(t * 3) * 0.05) }

    let rise = backOut(prog(t, 12.3, 12.9))
    if t > 12.3 {
        dog(pingpong(STAND, t, fps: 15), cx: dogHome.x, bottom: lerp(H + 360, dogHome.y, rise), height: 330)
        bubble("汪！淀粉肠！", cx: dogHome.x, bottom: dogHome.y - 345, alpha: prog(t, 12.8, 13.1))
    }
}

func scene4(_ t: Double) {
    desktop(t)
    caption("它站起来作揖，一蹦一蹦地追", t, from: 15.1, y: 150, color: rgb(0xffffff), until: 19.4)
    let eatT = 19.45
    let (sx, sy) = sausagePos(t)
    let s = chaseState(t)
    if t < eatT {
        let hop = s.moving ? abs(sin((t - chaseStart) * .pi / 0.3)) * 18 : 0
        dog(pingpong(BEG, t, fps: 15), cx: s.x, bottom: s.y - hop, height: 300, flip: !s.left)
    } else {
        let b = prog(t, eatT, eatT + 0.75)
        let jump = sin(b * .pi) * 40 + (b > 0.6 ? sin((b - 0.6) / 0.4 * .pi) * 14 : 0)
        dog(pingpong(STAND, t, fps: 15), cx: s.x, bottom: s.y - jump, height: 300)
        bubble("嗷呜～好吃！", cx: s.x, bottom: s.y - 320 - jump, alpha: prog(t, eatT + 0.1, eatT + 0.35))
        caption("追上就吃掉", t, from: eatT + 0.1, y: 150, color: rgb(0xffffff))
    }
    if t < eatT + 0.3 {
        // 吃的时候淀粉肠缩进小狗嘴里
        let e = easeInOut(prog(t, eatT - 0.35, eatT + 0.2))
        let mx = lerp(sx, s.x, e), my = lerp(sy, s.y - 230, e)
        sausage(mx, my, scale: 1 - prog(t, eatT, eatT + 0.25), rot: sin(t * 3) * 0.05)
    }
}

func scene5(_ t: Double) {
    gradient(0xf6f2ea, 0xece6da)
    caption("点它一下，清掉会话里的旧图片", t, from: 20.6, y: 120)
    caption("对话结构不变，照常继续聊", t, from: 24.3, y: 205, size: 42, color: rgb(0x6b6b73))

    let dx = 520.0, db = 900.0
    let click = 21.3, done = 23.15
    if t < click + 0.05 {
        dog(LOOK[0], cx: dx, bottom: db, height: 380)
    } else if t < done {
        dog(pingpong(STAND, t, fps: 15), cx: dx, bottom: db, height: 400, rot: sin(t * 2 * .pi / 0.24) * 0.07)
        bubble("呜呜，正在清理…", cx: dx, bottom: db - 420, alpha: prog(t, click + 0.1, click + 0.3))
    } else {
        let b = prog(t, done, done + 0.75)
        let jump = sin(b * .pi) * 40
        dog(pingpong(STAND, t, fps: 15), cx: dx, bottom: db - jump, height: 400)
        bubble("清掉 12 张图，每轮少传 106 MB！", cx: dx, bottom: db - 420 - jump, alpha: prog(t, done + 0.1, done + 0.3), size: 30)
    }
    // 光标点一下
    let mv = easeInOut(prog(t, 20.7, 21.2))
    let ax = lerp(860, dx + 10, mv), ay = lerp(660, 700, mv)
    if t < 22.2 { arrow(ax, ay, alpha: 1 - prog(t, 21.9, 22.2)) }
    if t > click && t < click + 0.5 {
        let p = prog(t, click, click + 0.5)
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0x5b8def, 1 - p))
        ctx.setLineWidth(5)
        let r = 20 + p * 70
        ctx.strokeEllipse(in: CGRect(x: ax - r, y: ay - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    // 右边：会话里的图片一张张变成 1×1 占位图
    for k in 0..<12 {
        let col = Double(k % 4), row = Double(k / 4)
        let cx = 1060 + col * 200, cy = 360 + row * 160
        let st = 21.6 + Double(k) * 0.12
        let p = easeInOut(prog(t, st, st + 0.3))
        if p < 1 { card(cx, cy, 170, 126, hue: k, scale: 1 - p * 0.92) }
        if p > 0.6 { fill(CGRect(x: cx - 7, y: cy - 7, width: 14, height: 14), rgb(0xb9b6ad, prog(p, 0.6, 1)), radius: 3) }
    }
    let q = easeInOut(prog(t, 21.6, 23.1))
    let mb = lerp(106, 0.2, q)
    text("每轮上传", 1000, 860, size: 32, weight: "Medium", color: rgb(0x55555c), align: 0)
    text(String(format: mb < 1 ? "%.1f MB" : "%.0f MB", mb), 1150, 860, size: 52,
         color: lerpColor(0xd0453b, 0x2f9e5b, q), align: 0)
    quotaBar(x: 1000, y: 960, w: 620, frac: lerp(0.18, 1, q), label: "")
}

func scene6(_ t: Double) {
    gradient(0xeef6f0, 0xe2efe6)
    caption("✓ 新版已修复：清理后聊天记录一条不丢", t, from: 26.6, y: 130, size: 56, color: rgb(0x1e7a46))
    let panel = CGRect(x: 520, y: 240, width: 880, height: 640)
    fill(panel, rgb(0xffffff), radius: 28, shadow: 22)
    let titles = ["做一个有趣的小游戏", "App 审核被拒了，帮我看看", "从 0 开始教我作曲编曲", "修一下登录页的 bug", "整理客户资料表", "写这周的周报"]
    for (i, s) in titles.enumerated() {
        let y = panel.minY + 60 + Double(i) * 98
        let fix = prog(t, 27.2 + Double(i) * 0.28, 27.45 + Double(i) * 0.28)
        if i > 0 { fill(CGRect(x: panel.minX + 40, y: y - 49, width: panel.width - 80, height: 2), rgb(0xeeeeee)) }
        text(s, panel.minX + 60, y, size: 34, weight: "Medium", color: rgb(0x1c1c1e), alpha: 0.35 + 0.65 * fix, align: 0)
        // 修复前：记录打不开；修复后：打勾
        text("记录为空", panel.maxX - 60, y, size: 26, weight: "Medium", color: rgb(0xd0453b), alpha: 1 - fix, align: 1)
        if fix > 0 {
            let r = 22 * backOut(fix)
            fill(CGRect(x: panel.maxX - 82 - r, y: y - r, width: r * 2, height: r * 2), rgb(0x2f9e5b), radius: r)
            text("✓", panel.maxX - 82, y, size: 28 * backOut(fix), color: rgb(0xffffff))
        }
    }
    caption("清理时保持每行字节数不变，Codex 的索引始终对得上", t, from: 28.2, y: 950, size: 34, color: rgb(0x55555c))
    dog(pingpong(LOOK, t - 26.5, fps: 6), cx: 1690, bottom: H - 30, height: 280)
}

func scene7(_ t: Double) {
    gradient(0xfff6e9, 0xf8ead6)
    caption("平时，它就是一只普通的小狗", t, from: 30.1, y: 130)
    let items: [(String, Double)] = [("闲着会张望", 400), ("摸久了翻肚皮", 960), ("没人理就睡觉", 1520)]
    for (i, it) in items.enumerated() {
        let a = backOut(prog(t, 30.3 + Double(i) * 0.3, 30.8 + Double(i) * 0.3))
        guard a > 0.01 else { continue }
        ctx.saveGState()
        ctx.translateBy(x: it.1, y: 580)
        ctx.scaleBy(x: a, y: a)
        ctx.translateBy(x: -it.1, y: -580)
        let r = CGRect(x: it.1 - 250, y: 260, width: 500, height: 640)
        fill(r, rgb(0xffffff), radius: 30, shadow: 20)
        switch i {
        case 0:
            dog(pingpong(LOOK, t - 30.3, fps: 10), cx: it.1, bottom: 780, height: 420, shadow: false)
        case 1:
            dog(BELLY, cx: it.1, bottom: 740, height: 300, rot: sin(t * 2 * .pi / 0.9) * 0.05, shadow: false)
        default:
            dog(SLEEP, cx: it.1, bottom: 740, height: 300, sy: 1 + sin(t * 2 * .pi / 2.4) * 0.03, shadow: false)
            for k in 0..<3 {
                let p = ((t - 30.9) / 2.1 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                guard t > 30.9, p >= 0 else { continue }
                text("Z", it.1 + 110 + p * 70, 470 - p * 150, size: 30 + p * 26, color: rgb(0x5b6b8c),
                     alpha: sin(p * .pi))
            }
        }
        text(it.0, it.1, 840, size: 40)
        ctx.restoreGState()
    }
}

func scene8(_ t: Double) {
    gradient(0x0f1724, 0x1d2b40)
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: 600, height: 380)
    text("小黑 CodexDog", W / 2, 690, size: 84, color: rgb(0xffffff), alpha: prog(t, 34.2, 34.7))
    text("给 Codex 省流量的 macOS 桌宠", W / 2, 775, size: 40, weight: "Medium", color: rgb(0xb8c4d6), alpha: prog(t, 34.5, 35.0))
    text("github.com/zio005792-blip/CodexDog", W / 2, 865, size: 38, color: rgb(0x7fd1ff), alpha: prog(t, 34.8, 35.3), mono: true)
    text("MIT 开源 · 一行命令安装", W / 2, 935, size: 30, weight: "Medium", color: rgb(0x8a96a8), alpha: prog(t, 35.1, 35.6))
}

let cuts = [3.5, 10.0, 20.5, 26.5, 30.0, 34.0]

func render(_ t: Double) {
    ctx.saveGState()
    switch t {
    case ..<3.5: scene1(t)
    case ..<10.0: scene2(t)
    case ..<15.0: scene3(t)
    case ..<20.5: scene4(t)
    case ..<26.5: scene5(t)
    case ..<30.0: scene6(t)
    case ..<34.0: scene7(t)
    default: scene8(t)
    }
    ctx.restoreGState()
    // 转场：短暂压暗
    var dip = 0.0
    for c in cuts { dip = max(dip, 1 - abs(t - c) / 0.22) }
    dip = max(dip, prog(t, DUR - 0.6, DUR), 1 - prog(t, 0, 0.4))
    if dip > 0 { fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(0x0f1724, dip)) }
}

// MARK: - 输出

func makeContext(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    let c = CGContext(data: data, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: H)
    c.scaleBy(x: 1, y: -1)
    c.interpolationQuality = .high
    c.setShouldSmoothFonts(false)
    return c
}

let args = CommandLine.arguments
if args.count > 3 && args[1] == "--still" {
    for s in args[2].split(separator: ",") {
        let t = Double(s)!
        ctx = makeContext(nil, bytesPerRow: Int(W) * 4)
        render(t)
        let url = URL(fileURLWithPath: args[3]).appendingPathComponent(String(format: "still_%05.2f.png", t))
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "xiaohei_intro.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let total = Int(DUR * FPS)
for f in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    ctx = makeContext(CVPixelBufferGetBaseAddress(pb!), bytesPerRow: CVPixelBufferGetBytesPerRow(pb!))
    render(Double(f) / FPS)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % 150 == 0 { print("frame \(f)/\(total)") }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(writer.status == .completed ? "done \(out.path)" : "failed \(String(describing: writer.error))")
