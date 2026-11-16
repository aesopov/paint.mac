# Paint.MAC

A native macOS raster editor inspired by the direct, approachable workflow of Paint.NET. Written from scratch in Swift, using AppKit for the interface and Metal-backed Core Image for layer compositing and adjustments.

**Status:** working 0.16.1 prototype. The working name is Paint.MAC; it is an independent project with its own code and file format.

Right-click a layer row for rename, duplicate, visibility, lock, grouping/reordering, merge, clipping, and mask actions. Text/effect layers expose their edit actions; groups expose collapse/expand and ungroup. Actions respect locks, clipping stacks, group rules, and layer limits. Right-clicking an unselected row selects it; right-clicking a selected row preserves the multi-selection and offers bulk grouping/movement/deletion. Shift-F10 or the accessibility Show Menu action opens the selected row’s menu.

Editor actions use a bundled subset of **Adobe Spectrum Workflow Icons 1.7.0**, including the legacy Merge Layers glyph. SVG sources and vector PDF conversions, the Apache 2.0 license, copyright notice, and provenance are included in `Sources/PaintMac/Resources/Spectrum` and the standalone app’s resource bundle. Native template tinting follows light/dark appearance and disabled states. Standard macOS controls retain SF Symbols. Normal builds need no network or icon tooling; `python3 scripts/vendor-spectrum-icons.py` regenerates the pinned subset with upstream SHA-512 verification and requires `curl` and `rsvg-convert`. Paint.MAC is independent of Adobe.

## Color and resolution

Use **Image → Color & Resolution…** to convert between sRGB, Display P3, and Adobe RGB (1998), choose 8 or 16 bits per channel, and set horizontal/vertical resolution in pixels per inch (PPI). Embedded RGB ICC profiles are preserved on import and remain available in the dialog. Converting to a narrower gamut can clip colors; reducing to 8 bits discards precision. Undo restores the previous format and pixels.

Print dimensions can be entered in inches or centimeters. With **Resample pixels** off, changing PPI/print size leaves pixel dimensions and artwork untouched. With it on, print dimensions and PPI determine new pixel dimensions; layers, masks, text geometry, and selections scale together. Existing Image & Canvas Size controls still handle pixel/percentage dimensions and canvas edges. New and legacy documents default to 72 PPI.

PNG and TIFF exports preserve 8/16-bit RGB, the color profile, transparency, and resolution. JPEG exports convert to 8-bit sRGB on white and preserve resolution. ICO/ICNS exports convert to 8-bit sRGB. Imports above 8 bits use 16-bit editing. CMYK/grayscale inputs are converted to RGB; native CMYK editing, print soft proofing, and HDR/32-bit float documents are not supported yet. Hex color fields use sRGB; the native picker and eyedropper can retain wide-gamut RGB colors.

Projects with nondefault color settings or resolution use **version 6**: `document.json` stores the RGB ICC profile, channel precision, and PPI, and each image/text layer uses an exact raw premultiplied `.rgba` payload (top-left rows, RGBA channel order, 16-bit samples little-endian). Masks stay L8. This avoids PNG alpha round-trip rounding in the editable project. Projects using default 8-bit sRGB at 72 PPI keep the previous minimum v1–v5 version. Old app builds cannot open v6 projects. Undo cache tile payloads preserve the full precision; session history is still excluded from projects.

## Build and run

Requires macOS 14 or later and a recent Xcode with Swift 6 support. There are no third-party dependencies.

```sh
git clone https://github.com/aesopov/paint.mac.git
cd paint.mac
./scripts/build-app.sh release
open build/Paint.MAC.app
```

The script builds an optimized app, generates its icon, and applies a local ad-hoc signature. Use `./scripts/build-app.sh` for a debug build. The locally generated app is not notarized for distribution.

Open `Package.swift` in Xcode to work on the project. Run the tests with:

```sh
swift test
```

GPU regression tests compare drawable pixels with exported pixels, including alpha, masks, effects, text, orientation, and zoom. To compare the previous Core Graphics display path with direct Metal rendering on a synthetic multilayer document, run:

```sh
PAINTMAC_METAL_BENCHMARK=1 swift test -c release --filter MetalCanvasTests/testRenderingBenchmarkWhenRequested
```

## What works

- Native light and dark appearances follow macOS, including changes while an editor is open. A thin border separates the canvas viewport from the panels. Drag the divider beside Colors & Layers to resize the right panel; double-click it to reset. The chosen width is remembered for new windows and launches.
- Metal canvas: layer compositing and live text/effect previews render directly to a viewport-sized drawable, without an intermediate CPU composite. Rendering is on demand; moving the brush cursor or changing a selection redraws only the AppKit overlay. Zoom uses crisp nearest-neighbor sampling at 100% and above, with smooth downsampling below 100%, including on Retina displays and in the Core Graphics fallback. This display filtering is independent of the drawing tool's Sharp/Smooth setting. Core Graphics remains available for export, color sampling, offscreen snapshots, and fallback when Metal is unavailable or fails.
- Brush and eraser with adjustable size, opacity, and hardness. Soft strokes keep event overlaps from building dark seams.
- Main and alternate colors: left/right mouse painting, palette assignment, and color picking. X swaps the colors.
- Contiguous paint bucket with adjustable tolerance, and a color picker.
- Lines, rectangles, and ellipses with a shared Sharp/Smooth edge toggle; rectangles and ellipses can also be filled with the opposite color. Brushes, erasing, text, and selection shapes also honor the edge mode.
- Text tool with inline multiline editing in a movable, resizable canvas box, font family, size, bold, and italic. Text uses the main/alternate color and remains editable as a text layer, with an exact raster preview and explicit rasterization for pixel editing.
- Rectangle, ellipse, and freehand lasso selections, with replace/add/subtract/intersect modes, disconnected regions, and holes.
- Feather Selection (Gaussian radius 0–200 px), Invert Selection, and undo/redo of selection edits.
- Mask-aware painting, shapes, fill, erasing, adjustments, delete, move, copy, cut, and paste as a layer. Crop trims to the selection's bounding box.
- Move selected pixels or the complete active layer.
- Add, duplicate, rename, reorder, hide, merge, and delete layers; change layer opacity.
- Nested layer groups with collapse/expand, multi-selection grouping, group visibility/opacity/masks, and moving layers between groups.
- Clipping masks constrain one or more layers to the transparency of the base below them, within the same group.
- Nondestructive effect layers: Gaussian blur, brightness/contrast, hue/saturation, grayscale, and invert, with live previews and editable parameters.
- Nondestructive layer masks: create from a selection or reveal/hide all, edit with painting tools, invert, feather, disable, delete, or apply.
- Undo/redo for document edits, including layer changes, crop, and resize.
- Zoom around the pointer, pinch to zoom, pan, fit to window, and actual size.
- Image import through ImageIO, including photograph orientation.
- Native layered `.paintmac` projects with standard document saving and autosave.
- PNG export with transparency; JPEG export with a white background; built-in Windows ICO and macOS ICNS import/export with multiple icon sizes and Retina slots.
- Image & Canvas Size dialog: scale pixels or resize the canvas with pixel/percent dimensions, a nine-position anchor, and independent edge changes. Selections transform with the image. Growing the canvas adds transparent space.
- Crop tool trims every layer to the current selection bounds. Invert colors and grayscale respect mask coverage.
- Multi-file opening in native document tabs. Control-Tab switches documents; tabs can be moved to separate windows.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Brush / Eraser | B / E |
| Rectangle Select / Move Pixels | S / V |
| Ellipse Select / Lasso Select | M / A |
| Quick Mask | Q |
| Paint Bucket / Color Picker | F / I |
| Line / Rectangle / Ellipse | L / R / O |
| Text / Crop to current selection | T / C |
| Hand / temporary pan | H / hold Space and drag / middle-button drag |
| Brush size | [ / ] |
| Main / alternate drawing color | Left / right mouse |
| Swap main and alternate colors | X |
| Constrain drawn shapes | Shift while dragging |
| Constrain rectangle/ellipse selections | Control while dragging |
| Add / subtract / intersect selection | Shift / Option / Shift-Option when starting a selection |
| Draw shapes from center | Hold Option while dragging |
| Draw rectangle/ellipse marquee from center | Start dragging, then hold Option |
| Sample visible color | Option-click with brush/eraser or use Color Picker |
| Zoom around pointer | Mouse wheel or pinch |
| Pan with wheel | Option-scroll (both axes) / Shift-scroll (horizontal) |
| Fit / Actual size | Command-0 / Command-1 |
| Save layered project | Command-S |
| Export PNG/JPEG/ICO/ICNS | Shift-Command-E |
| Import as layer | Shift-Command-O |
| Add / Duplicate layer | Shift-Command-N / Shift-Command-D |
| Merge current layer down | Shift-Command-M |
| Group selected / Ungroup | Command-G / Shift-Command-G |
| Create / Release clipping mask | Option-Command-G |
| Crop to selection | Shift-Command-K |
| Deselect | Command-D or Escape |
| Invert Selection | Option-Command-I |
| Image & Canvas Size | Option-Command-R |
| Open multiple files | Command-O, then Shift/Command-select files |
| Next / previous document tab | Control-Tab / Shift-Control-Tab |

Select a layer and click **Merge Down** at the bottom of the Layers panel, or use **Layer → Merge Down** (Shift-Command-M), to combine it with the lower sibling. Clipping stacks merge together so their appearance remains intact: on a clipped layer this merges its whole stack; on a base layer it merges that stack with the one below. The command is disabled for the bottom unclipped sibling. It bakes current visibility, masks, and opacity into the merged pixels, keeps the lowest layer’s name, and leaves the selection and other layers unchanged. Undo restores the original layers. A selected group changes the panel button to **Merge Group**.

Press the opposite mouse button during a gesture to cancel it: LMB then RMB, or RMB then LMB. The canvas returns to its starting state without adding an undo step. Release both buttons before starting another gesture. This also works for erasing, shapes, fill, selections, moving pixels, text-box creation, and panning.

Double-click an image/group layer to rename it; text and effect layers reopen their editors. **Layer → Rename Layer…** renames any layer. Hold the middle mouse button (wheel click) and drag to pan with any tool, including over an active text box; this preserves the text draft and selected tool. Scrolling zooms around the pointer by default: wheel up zooms in and wheel down zooms out regardless of Natural Scrolling. Hold Option to pan, or Shift to pan horizontally; panning follows the macOS scroll direction setting. Holding Space also temporarily switches scrolling to pan. Clipboard copy uses the active layer.

Select layer rows and press Delete/Forward Delete, click the trash button, or drag rows onto the panel's trash button to delete them. Deletion supports undo and always keeps at least one layer. Delete on the canvas still clears pixels; Delete while typing edits text.

Click the lock beside a layer, or choose **Layer → Lock Layer**, to protect its pixels, mask, text/effect settings, opacity, position, and deletion. A group lock protects all its children and prevents adding or removing contents. Unlock the parent group to edit its children. Locked layers can still be selected, hidden, renamed, and copied. Lock/unlock supports undo and is saved in `.paintmac` projects. Whole-image scale, canvas resize, and crop still apply to every layer and retain lock state.

Drag the thin divider between the canvas and **Colors & Layers** to widen or narrow the inspector. Color fields, sliders, menus, and layer names use the additional space. Its minimum width keeps the controls usable, and the canvas retains at least 320 points. Window resizing temporarily clamps an oversized inspector and restores your preferred width when space returns. Double-click the divider to reset to the default width. Resizing preserves zoom, selections, undo history, and active inline text.

## Layer groups and clipping masks

Command-click or Shift-click layer rows to select adjacent layers, then choose **Layer → Group Selected Layers** (Command-G), or use **Layers ▾** beneath the layer list. **New Group** creates an empty folder; with a group selected, Add Layer or Import as Layer places new artwork inside it. Disclosure arrows after the eye button collapse/expand folders. Small checkerboards in layer thumbnails show transparent pixels. **Layers ▾ → Move to Group** moves selected layers into an existing group or back to **Top Level**. Drag layer rows between rows to reorder them, or onto a group to move them inside. Dragging carries groups with all their descendants and keeps clipping stacks together. The up/down buttons reorder within the current parent. Grouping and structural moves carry entire clipping stacks together.

Groups support nesting up to eight levels, their own visibility, opacity, and grayscale mask. Opacity and masks apply once to the combined contents. Groups use isolated Normal blending. The Move tool moves all descendant pixels and masks together; click the group mask to move or paint just that mask. With a group selected, brush, fill, and shape drawing automatically create and select a paint layer inside it. The new layer and drawing share one undo step; cancelling restores the original group selection and contents. Empty gestures create no layer. Text creates an editable text child. Erasing requires selecting an existing image layer or group mask. Copy copies the group's visible contents; Cut/Delete and image adjustments require an image layer or mask target.

**Ungroup** (Shift-Command-G) releases a visible 100% group without a mask, clipping, or direct unclipped effect layers. For groups with those effects, **Merge Group** preserves the current appearance in one raster layer. Applying a group mask is explicitly labeled **Apply Mask & Merge Group**, since baking it correctly requires merging the group. Duplicate, delete, merge, group, ungroup, and move operations support undo.

Select an upper layer and choose **Create Clipping Mask** (Option-Command-G). It paints only where the bottom, unclipped base of its stack is visible. More clipped layers can share the same base. A turn-down arrow identifies clipped layers; the base name is underlined. Base opacity applies to the whole stack, while clipped layers keep their own opacity and masks. A hidden base hides the stack; clipping never crosses a group boundary. Groups can serve as clipping bases or be clipped themselves. Choose **Release Clipping Mask** to detach the selected layer.

## Layer masks

Use the **Layer Mask** menu beneath the layer controls, or **Layer → Layer Mask**. Choose **Add Mask — Reveal All**, **Add Mask — Hide All**, or **Mask from Selection**. Creating a mask from a selection keeps its holes and feathering and then deselects, allowing you to refine the mask freely. Each layer supports one grayscale raster mask.

Click the mask thumbnail beside the image thumbnail to edit visibility: **black hides**, **white reveals**, and gray gives partial transparency. A blue border identifies the editing target. The palette switches to grayscale, with true black as the main color and white as the alternate. LMB hides, RMB reveals, and X swaps them. Choose other gray values for partial visibility. Clicking the image thumbnail restores your image-painting colors. Mask editing respects selections, opacity, and Sharp/Smooth and works with brush, eraser, fill, shapes, text, and adjustments. Eraser and Delete hide masked regions without erasing original image pixels.

The menu also offers **Invert Mask**, **Feather Mask…** (0–200 image pixels), **Disable/Enable Mask**, **Delete Mask**, and **Apply Mask**. Disabled masks remain editable and show a red slash on their thumbnail. Delete removes the mask and reveals the original image. Apply permanently multiplies mask coverage into image transparency, including a disabled mask. All operations support undo/redo.

Moving image pixels moves the mask with them; selecting the mask thumbnail lets you move just the mask. Scale, canvas resize, crop, and duplicate preserve masks; merge bakes the visible masked appearance. Exports include enabled masks. Save `.paintmac` projects to retain editable masks and their enabled state.

## Selections and feathering

The tool rail groups **Selections** (Rectangle, Ellipse, Lasso) and **Shapes** (Rectangle, Ellipse, Line). Each button shows and remembers its last type. Hover to open a menu on the right, where a checkmark identifies the current type; click a row to choose another. Clicking the rail button selects its remembered type. Right-click also opens the menu; use Up/Down and Return to choose, or Escape to close. Existing tool shortcuts update the remembered type. Hovering preserves text drafts, focus, selections, and undo history.

Choose Rectangle Select (S), Ellipse Select (M), or Lasso Select (A). The options bar offers Replace, Add, Subtract, and Intersect. Hold Shift to add, Option to subtract, or both to intersect when beginning a gesture; these modifiers override the options-bar mode for that gesture. Control constrains rectangle and ellipse dimensions. Escape cancels an in-progress selection or deselects when idle.

Use **Selection → Feather Selection…**, or the **Feather…** button, to soften the current selection with a Gaussian radius in image pixels. This blurs mask coverage, not image pixels. Painting and subsequent edits fade across the softened edge. The outline follows 50% coverage; the shading also shows softer coverage beyond it. Feathering can be applied repeatedly or undone. **Selection → Invert Selection** selects the opposite coverage, including holes and disconnected areas.

Selection changes share undo history with pixel edits. Deselect explicitly removes the constraint; an empty mask created by subtraction continues to select nothing until you deselect or add another region. Selections and history are session state and are not stored in `.paintmac` packages.

## Text, edge quality, and canvas sizing

Choose **Text (T)** and drag a rectangle directly on the canvas (a click creates a default box). Type multiline text in place. Choose the font family, size in image pixels, bold, and italic in the options bar. Drag **Move text** to reposition the box, or its bottom-right corner to resize it. Text wraps to the box width and clips at its edges without scrollbars, including partially visible letters and lines.

The canvas previews rasterized pixels as you type, including color, opacity, Sharp/Smooth, selection coverage, and all layers/effects. Zoom magnifies those same pixels. Click outside the box or press **Command-Return** to finish as one undoable edit; **Escape** cancels. Switching tools/layers, saving, or exporting also finishes pending text. There are no Apply or cancel buttons. Right-drag starts text in the alternate color.

Text remains editable after finishing. Double-click its row/thumbnail, double-click its box on the canvas, or choose **Layer → Edit Text / Effect…** to reopen the text, font, color, opacity, quality, and box geometry. An empty image layer becomes a text layer; drawing text over painted pixels creates a separate layer above, or inside the selected group. Editing a layer mask still paints raster text into the mask. A selection used when creating text is retained as a creation clip, including its holes and feathering; later selections do not silently alter that text.

Text layers support masks, clipping, opacity, visibility, grouping, duplication, movement, crop, and resize. Move treats text as a complete editable object. Image scaling adjusts its typography and horizontal scale; canvas resize/crop preserve its layout, including boxes extending beyond the new canvas. Text is rerendered after image scaling so future edits have the same pixel preview. Fonts are referenced by family and traits, not embedded; the saved raster cache preserves appearance on open, while editing uses installed fonts with a system-font fallback.

Brush, eraser, fill, destructive adjustments, Cut, and Delete require an image layer or mask. Choose **Layer → Rasterize Text Layer** to convert text to pixels explicitly; this preserves its current raster, masks, opacity, and clipping and supports undo. Applying a text mask is labeled **Apply Mask & Rasterize Text**. Merge operations also bake text. Already rasterized text from older projects remains pixels.

For **Rectangle** and **Ellipse**, enable **Filled** in the tool options to paint the interior. Left-drag uses the main color for the outline and alternate color for the fill; right-drag swaps them. Uncheck Filled for an outline only. Size controls outline thickness, and Opacity applies once to the whole shape. Both colors respect selections, feathering, and mask editing. The option stays selected when switching tools and does not affect lines.

**Hardness** controls brush/eraser falloff and line, rectangle, and ellipse outlines: 100% retains the hard edge, while 0% fades gradually from the center to the edge. Filled interiors keep their alternate color; only the outline softens. The value stays selected when switching tools. Soft brush/eraser strokes blend evenly spaced dabs so crossings have smooth falloffs. Spacing is independent of mouse-event frequency; stationary input adds no paint. Opacity, color alpha, and selection coverage apply once against the raster at the start of the gesture, so crossings cannot exceed tool opacity. Separate strokes can still build opacity. Masks and selections retain their partial coverage.

**Smooth** enables antialiasing; **Sharp** disables it for new brush/eraser strokes, lines and shapes, text, and curved/freehand selections. Shift-constrained drawn shapes snap their anchor and side length in Sharp mode so the pixel width and height match. A click with any selection tool deselects instead of creating a one-pixel mask. Sharp still honors intentional opacity, brush hardness falloff, and feathered selection coverage. Fill operates on connected pixels without generating an antialiased outline.

Open **Image → Image & Canvas Size…** (Option-Command-R):

- **Scale Image** resamples all layers to the new dimensions. Keep proportions can link width and height. Smooth uses high-quality interpolation; Sharp uses nearest-neighbor sampling.
- **Resize Canvas** changes the document bounds without resampling pixels. Choose an anchor to keep an edge/corner/center fixed, or specify Left/Top/Right/Bottom amounts directly. Positive amounts add transparent space; negative amounts crop it. In Percent mode, horizontal amounts are relative to the original width and vertical amounts to the original height.

Both modes preserve layer properties and transform the selection, and can be undone. Choose **Crop (C)**, or Shift-Command-K, to immediately trim the canvas to the current selection's bounding rectangle. Nonrectangular selections still produce a rectangular canvas. The tool rail scrolls when the window is too short to show every tool.

## Effect layers

Choose **Layer → New Effect Layer** or **Layers ▾ → New Effect Layer**. The first effects are **Gaussian Blur**, **Brightness & Contrast**, **Hue & Saturation**, **Grayscale**, and **Invert Colors**. The settings sheet previews the result on the canvas. Apply creates one undo step; Cancel discards the preview without changing document state or history. Double-click an effect layer or use **Edit Text / Effect…** to adjust it later.

An effect processes the visible composite of its lower siblings within the same group. Layers above it remain unaffected, and edits to layers below update the effect automatically. Grouping or moving an effect deliberately changes that scope; isolated groups do not pass effects through to outside layers. Initial selections become editable effect masks. Layer opacity sets effect strength, and enabled grayscale masks blend the effect spatially. Mask editing works with all existing tools; there are no image pixels to paint directly on an effect layer.

Clipping an effect restricts it to its base stack and retains that stack's silhouette, including with blur. The base opacity still applies once. Effect layers cannot serve as clipping bases themselves; releasing a clipped effect also releases the remaining clipped layers above it in that stack. An unclipped blur may spread transparency within the canvas, while a clipped blur keeps the base alpha.

**Merge Below** on an effect bakes its input layers together. Merging an image immediately above an effect also includes the lower input prefix needed to preserve the visible result. A clipped effect merges its clipping stack. Group merge bakes all internal effects. Applying an effect mask is labeled **Apply Mask & Merge Below** and includes a disabled mask explicitly. All these operations support undo. Export includes visible effects; save `.paintmac` to retain editable settings.

## Windows icons (.ico)

Open `.ico` files with **File → Open** or **Import as Layer**. When an icon contains several images, choose the size/color depth to edit; the largest image is selected initially. Icon representations are alternate images, not compositing layers. Transparency is preserved. The built-in codec reads PNG images and Windows DIB images at 1, 4, 8, 16, 24, or 32 bits per pixel, including transparency masks and RGB bitfields. OS/2 bitmap headers, RLE compression, CUR files, and legacy screen-inversion pixels are not supported.

Use **File → Export Image…** (Shift-Command-E) and select **Windows icon (.ico)**:

- **Current size** writes one image at the canvas dimensions, between 1 and 256 pixels on each side.
- **Windows size set** generates 16, 24, 32, 48, 64, 128, and 256 pixel images. Choose Smooth or Sharp scaling. Nonsquare artwork fits inside each square with transparent padding, preserving its proportions.
- **Update opened icon · keep other images** replaces the representation you opened and copies the other original representations unchanged. This is the default when exporting an opened ICO. Smaller sizes use 32-bit DIBs with an AND mask; 256-pixel images use PNG. Export includes the visible composite of all document layers.

Command-S continues to save layered `.paintmac` projects; use Export to write an ICO. The source icon container is retained for the current editing session only; reopening a saved `.paintmac` project does not restore the unedited source representations. If the same ICO is opened in separate documents, each keeps its own copy of the original container; their edits are not merged automatically.

ICO parsing and encoding are independent of the editor UI and native project format, leaving room for future format extensions. There is no plugin loading in this release. The container implementation follows Microsoft's descriptions of [ICO directories and masks](https://devblogs.microsoft.com/oldnewthing/20101018-00/?p=12513/) and [PNG representations](https://devblogs.microsoft.com/oldnewthing/20101022-00/?p=12473/).

## macOS icons (.icns)

Open or import `.icns` files using the same workflow as ICO. The representation chooser shows **display size in points, scale (@1x or @2x), and pixel dimensions**. A 16 pt @2x image and a 32 pt @1x image both contain 32 × 32 pixels but can have different artwork; their identities are preserved throughout editing and export. The largest standard slot, 512 pt @2x, contains 1024 × 1024 pixels. See [Apple's high-resolution icon guidance](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html).

Choose **macOS icon (.icns)** in Export Image:

- **Current size** writes one matching slot. When dimensions have multiple meanings, choose its display size and Retina scale. Supported square pixel dimensions are 16, 32, 48, 64, 128, 256, 512, and 1024.
- **macOS set · standard + Retina** creates all ten standard slots: 16, 32, 128, 256, and 512 pt, each at @1x and @2x. Smooth/Sharp scaling and transparent padding work as in ICO export. Generated variants share the current artwork; opening an existing icon lets you edit its individually designed variants.
- **Update opened icon · keep other images** updates exactly the opened slot and any associated transparency mask. Its pixel dimensions must still match that slot. Other representations, unknown resources, and metadata are retained; a resource table of contents, if present, is rebuilt.

PNG and JPEG 2000 image resources use ImageIO. Common older ARGB, RGB/mask, indexed, and monochrome resources also use Apple's decoder, with the chosen resource isolated so another same-size slot cannot be substituted. Legacy indexed/monochrome representations can be opened, but in-place replacement requires a modern or RGB slot; export a complete macOS set to convert them. Nested icon variants and opaque resources are preserved but are not exposed as editable representations. ICNS contains alternate raster images, not editable layers.

As with ICO, Command-S saves the layered Paint.MAC project. Export writes the icon; the original ICNS container and its unedited resources are kept only for the current session, not serialized in `.paintmac` projects. No external tools are launched by the application; `iconutil` is used only in compatibility tests and app packaging.

## Project format

A `.paintmac` file is a macOS package containing `document.json` and a lossless PNG per image layer. The manifest records dimensions, ordering, visibility, opacity, and the active layer. Version 1 stores flat layers; version 2 adds lossless, top-left L8 `UUID.mask` payloads and enabled state. Payload lengths must match the validated canvas dimensions exactly. Version 3 adds group nodes, parent IDs, clipping flags, and folder expansion state; group nodes have no PNG. Version 4 adds typed text/effect metadata. Version 5 adds persistent layer locks. Text stores content/style/geometry, a lossless raster PNG cache, and an optional L8 `UUID.text-mask` creation clip. Effects store validated parameters without a PNG. Storage is bottom-to-top postorder, with descendants before each group header. Parent links, canonical order, clipping bases, and nesting limits are validated on read.

Existing version 1, 2, 3, and 4 projects remain readable. Projects save as version 1 without masks or hierarchy, version 2 with masks alone, version 3 with groups/clipping, version 4 with editable text/effects, or version 5 when any layer is locked. Masked projects require Paint.MAC 0.8 or later; grouped/clipped projects require 0.9 or later; editable text/effects require 0.10 or later; locked projects require 0.12 or later. Older versions reject newer manifests rather than silently losing features. The selected editing target, selection, and history remain session state. Native NSDocument saving provides atomic file replacement and autosave behavior.

## Code layout

- `BrushProfile.swift`: shared hardness falloff, per-gesture soft brush coverage, and bounded grayscale masks for soft shape outlines.
- `Raster.swift`: premultiplied RGBA8/RGBA16 pixels, brush rasterization, fill, crop, movement, and the Core Image compositor.
- `SelectionMask.swift`: immutable 8-bit coverage masks, shape creation, boolean combinations, contours, translation, inversion, and feathering. Further selection operations can be added without changing individual painting tools.
- `PaintDocument.swift`: document state, undo transactions, ImageIO, layered package encoding, and NSDocument integration.
- `ColorManagement.swift` / `ImagePropertiesDialog.swift`: tagged RGB profiles, integer precision, PPI/print-size planning, document conversion, and native controls.
- `PixelTiles.swift`: sparse immutable tile versions, bounded pixel access, mask conversion, and Core Image sources.
- `HistoryCache.swift`: compressed disk-backed tile history, integrity checks, session ownership, and cache budgets.
- `ICOCodec.swift`: bounded ICO container parsing, legacy DIB/PNG decoding, 32-bit export, size sets, and representation replacement.
- `ICNSCodec.swift`: bounded ICNS resources, logical/Retina slots, ImageIO decoding, standard-set generation, and resource-preserving replacement.
- `ImageFileIO.swift`: built-in format import/export boundary, icon representation chooser, and native export controls.
- `LayerTree.swift`: validated layer hierarchy, grouping, clipping stacks, subtree operations, and merge behavior.
- `LayerInteraction.swift`: hierarchy-safe drag reordering, trash drop targets, panel Delete handling, and persistent layer locks.
- `LayerMask.swift`: grayscale coverage conversion, nondestructive mask commands, and lossless mask editing.
- `LayerMaskControls.swift`: mask menu commands and pixel/mask thumbnail controls.
- `CanvasView.swift`: canvas drawing, coordinate conversion, selection overlays, pointer gestures, and tool shortcuts.
- `MetalCanvasView.swift`: on-demand Metal drawable presentation, viewport/Retina transforms, bounded GPU submissions, and the native overlay view.
- `EditorWindowController.swift`: native tool rail, inspector, layer controls, and editing commands.
- `InspectorSplitView.swift`: native inspector divider, minimum pane sizes, width preferences, and resize behavior.
- `EditorPanelView.swift`: appearance-aware panel backgrounds and layer selection highlighting.
- `EditableLayers.swift`: validated text/effect parameters, cached text rendering, and editable-layer commands.
- `EffectLayerDialog.swift`: native effect controls, live preview, and Apply/Cancel transactions.
- `TextTool.swift`: native inline text input, caret/selection, move/resize handles, keyboard commands, and font settings.
- `TextRasterLayout.swift`: shared TextKit layout for input geometry and clipped rasterization in `Raster.swift`.
- `CanvasSizing.swift`: dimension/edge/anchor calculations, atomic size changes, and the native scale/resize dialog.
- `App.swift`: launch, document creation/import, menus, and command validation.
- `Tests/PaintMacTests`: raster behavior, orientation/transparency, compositing, project validation, saving/export, window ownership, and undo/redo.

Pixel coordinates start at the top left. Layers are stored from bottom to top. Layers and masks use sparse, immutable 256 × 256 pixel tiles (smaller for small images). A gesture copies only changed tiles and registers one undo snapshot containing tile IDs and document metadata. Core Image uses Metal when available and falls back to its default renderer. The canvas renders the compositing graph directly into a Metal drawable in premultiplied Display P3 half-float output, sized to the viewport's backing pixels. Redraw requests are coalesced onto the AppKit run loop, including mouse tracking, and explicitly submit a frame after edits, zoom, pan, resize, and backing-scale changes. Up to three frames can be in flight; completion schedules any pending redraw without blocking input. Cursor and selection overlays and inline text controls remain native AppKit views. Export, sampling, snapshots, and the automatic non-Metal fallback use Core Graphics.

## Current limits and next steps

Pixel storage and undo history are tiled. Empty layers, group/effect placeholders, and uniform backgrounds/masks allocate no pixel tiles. Native tools edit bounded regions; soft-brush coverage allocates only touched tiles. Core Image assembles immutable tile images for Metal rendering, and thumbnails render directly to small previews. Some whole-image operations, import, saving, and export still use contiguous temporary buffers and synchronous CPU work. Active document pixels, GPU resources, and temporary buffers are separate from the history-cache budget, so very large images or many layers can still consume substantial memory. Images are limited to 8,192 pixels on either side, 32 million pixels total, and 32 total layer/group nodes. Imported layers retain their pixel size and are clipped if they exceed the canvas.

Only Normal layer blending is implemented. Layer styles (shadow/outline/glow), magic wand, gradients, transform handles, pressure-sensitive brushes, plugins, and Paint.NET `.pdn` compatibility are future work. Rectangles and ellipses use native paths for fast drawing even at large thicknesses, with uniform opacity across filled shapes. Native project saves preserve pixels and layers; undo history and the current selection are session state.

Undo uses a private, per-document session cache under `~/Library/Application Support/Paint.MAC/UndoCache-v1`. Unchanged tile versions are shared; older pixels are compressed with LZFSE and verified with SHA-256. Disk writes run on a utility queue; a tile stays in RAM until its file has been written and verified. The history cache targets 128 MiB of resident pixels and a 2 GiB allocated disk footprint; in-flight writes can temporarily exceed the RAM target. Completed oldest undo groups are pruned when the disk budget is exceeded. Metadata is capped separately at approximately 16 MiB, with a maximum of 500 recorded actions. History can exceed the previous 40-step limit. Cold undo may wait for disk reads; loading validates all required tiles before replacing the current state. If disk caching is unavailable, history falls back to its RAM budget. Cache sessions are removed on document close; exclusive session locks protect other running instances during abandoned-session cleanup. Undo is session-only and is not saved in projects. Existing v1–v5 projects remain readable; v6 preserves nondefault color/resolution settings.

The next engineering priority is moving expensive pixel edits and cold-history loading off the main thread. The next editing priorities are magic wand selections and transform handles.

### Quick Mask and off-image gestures

Drawing and selection gestures can start in the viewport outside the image; pixels are clipped to the image edges. The anchor stays outside, allowing partial rectangles, ellipses and brush strokes.

Press **Q** or click **Quick Mask** at the bottom of the tool rail to edit the selection as a temporary grayscale image. Red shows selected coverage; white adds and black or the eraser removes it. An unrestricted selection starts fully red. Brush hardness, opacity, shapes, bucket, text and adjustments work on this temporary mask. Selection tools create a local marquee that restricts mask edits; use Move to reposition the selected mask pixels. Press Q again to use the result as the normal selection. **A** now selects the lasso. Undo/redo restores the mode, mask and local marquee together, including disk-cached history. Quick Mask is session-only, and its red overlay is excluded from exports and project artwork.

### Center-origin geometry and outline alignment

Hold **Option** while drawing a rectangle, ellipse, or line to expand from the initial point in both directions; **Shift** still constrains shape proportions/line angles. For rectangle/ellipse marquees, begin dragging and then hold Option for a center origin; **Control** constrains the marquee. Modifiers can be pressed or released during the drag, updating the preview even without moving the pointer. Option held before starting a selection retains Subtract, and Shift+Option retains Intersect.

Rectangle/ellipse **Outline** offers **Inside**, **Center** (the existing default), and **Outside**. The dragged rectangle specifies the outer bound, stroke center, or inner bound respectively. For example, Inside keeps a 10-pixel outline within `(10, 10)…(100, 100)`; Center extends it to `(5, 5)…(105, 105)`. Marquees have no painted thickness and always use their exact boundary. Alignment works with fills, antialiasing, hardness, layer masks, Quick Mask, and high precision RGB. Scroll the options row horizontally if it exceeds the window width.
