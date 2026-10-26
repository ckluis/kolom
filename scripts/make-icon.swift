import AppKit
let directory=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let n=CGFloat(size)
    let image=NSImage(size:NSSize(width:n,height:n));image.lockFocus()
    NSColor(calibratedRed:0.11,green:0.14,blue:0.10,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:n*0.06,y:n*0.06,width:n*0.88,height:n*0.88),xRadius:n*0.19,yRadius:n*0.19).fill()
    NSColor(calibratedRed:0.83,green:1,blue:0.50,alpha:1).setFill()
    for (x,width) in [(0.20,0.10),(0.36,0.20),(0.62,0.18)] {
        if x==0.62 { for y in [0.22,0.53] { NSBezierPath(roundedRect:NSRect(x:n*x,y:n*y,width:n*width,height:n*0.25),xRadius:n*0.025,yRadius:n*0.025).fill() } }
        else { NSBezierPath(roundedRect:NSRect(x:n*x,y:n*0.22,width:n*width,height:n*0.56),xRadius:n*0.025,yRadius:n*0.025).fill() }
    }
    image.unlockFocus()
    guard let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]) else{fatalError("Could not render icon")}
    try data.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name+".png"))
}
