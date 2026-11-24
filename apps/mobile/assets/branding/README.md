# Whisplot logo

`app_logo.png` is the app logo supplied by the project owner, edited with the built-in image generation tool to make the area outside the blue rounded square transparent. The white open-lock/chat symbol remains white. The app header and macOS icon use this artwork. Android uses a vector mark with a full-bleed blue adaptive background and a matching legacy drawable.

Edit instruction: Remove only the outside white background; preserve the blue rounded square, central opaque white open-lock/chat-bubble symbol and two blue holes; no white fringe, outline, text or additional decoration.

Platform exports: macOS AppIcon sizes 16–1024 px are resized with macOS `sips`. Android launcher drawables are density-independent. iOS development remains paused and is not part of this release.

## Final edit prompt (built-in image generation)

> Use case: precise-object-edit. Edit target is the attached app logo. Make exactly one change: remove the white/off-white background OUTSIDE the large blue rounded square and replace it with true transparent alpha. Preserve the large vivid blue rounded square, its original corner curvature, and the central solid white open-padlock/chat-bubble symbol with the two blue circular holes, their exact shape, proportions and relative positions. The interior white symbol MUST remain opaque white, not transparent. Do not redesign, add texture, outlines, strokes, shadow, glow, text or decoration. Trim the outside blank margin so the blue rounded-square silhouette nearly fills the square canvas, with only a small transparent safety margin around it; corners outside the silhouette are fully transparent. Crisp clean antialiased boundary without a white fringe. Output a high-resolution square transparent PNG suitable as a mobile and desktop app icon.
