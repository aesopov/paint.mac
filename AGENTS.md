# Working on Paint.MAC

Paint.MAC is a native macOS Swift/AppKit application, distributed as a Swift package and assembled into an app bundle by `scripts/build-app.sh`.

- Keep pixel operations and project serialization separate from AppKit interaction code.
- Document pixels use top-left coordinates and premultiplied RGBA8 sRGB storage. Layer ordering is bottom to top.
- `DocumentState.selection` is an immutable `SelectionMask` with linear 8-bit coverage. Nil means unrestricted editing; an empty mask selects nothing. Respect partial coverage in every pixel operation, and preserve holes in clipboard and move operations.
- Selection state participates in undo snapshots but is intentionally omitted from v1 project serialization. Pixel and selection history must restore together after crop and resize.
- Register undo once per user gesture using `PaintDocument.commit` or `edit`. Native NSDocument undo notifications handle edited-state tracking.
- Pressing the opposite mouse button cancels an active gesture by restoring its starting snapshot without touching undo/redo history. Ignore both buttons until released; fill previews also remain uncommitted until mouse-up.
- Middle-button drag pans without changing the selected tool, pixels, history, or inline text drafts. Forward middle-button input through text overlays and preserve their keyboard focus.
- Let `NSDocument.addWindowController` establish document ownership; do not set a controller's `document` property before adding it.
- Preserve existing project files and manifest-version validation. Read v1/v2 projects; write v1 for flat unmasked projects, v2 for masks alone, v3 for groups/clipping, and v4 for editable text/effects. Validate exact L8 mask payload dimensions and preserve enabled state. Reject unsupported versions rather than dropping mask data.
- Run `swift test` after changes to raster behavior, history, or serialization. Build the app with `./scripts/build-app.sh release` to validate packaging.
- Avoid restarting a running app that contains an unsaved user canvas. Use a separate test document or the test suite for verification.
- Use native controls and AppKit input behavior. Rendering optimizations must preserve image orientation, alpha, and exported pixels.
- Inherit the system light/dark appearance. Resolve semantic panel colors in the view's effective appearance when updating backing layers, and refresh them on appearance changes; never freeze a startup CGColor or force dark mode.
- Sharp mode disables edge antialiasing without flattening intentional brush opacity or selection feathering. Keep this behavior consistent across raster tools and text.
- Canvas resize preserves pixel size and adds transparent padding; image scale resamples pixels. Prepare all resized layers before committing one history transaction, and transform selection masks alongside pixels.
- Inline text uses native NSEditor registration so close/quit detect drafts. Explicit save and document edits apply drafts; autosave defers while text is being entered. Keep draft undo separate from raster document history.
- Inline text displays raster pixels using the same layout as native input; commit the exact preview raster. Keep text layout vertically unbounded and clip its rendered pixels to the box so partial lines/glyphs survive. Do not introduce text scrollbars or native vector glyphs over the preview.
- Built-in image codecs live outside UI/document logic. ICO representations are alternate images, never compositing layers. Preserve untouched source payloads on replacement export; keep source-container context separate from v1 project serialization. Do not add dynamic plugin loading without a user request.
- ICNS slot identity includes point size and scale, not just pixel dimensions. Preserve unrelated resources and metadata on replacement, rebuild derived TOC resources, and update a selected legacy RGB resource together with its companion mask. Never choose a different same-size representation during decoding.

- Layer masks are immutable L8 coverage separate from original image pixels. Composite enabled masks before layer opacity. Route pixel tools to the selected image/mask target; true black hides, white reveals, gray is partial visibility. Preserve masks through duplication, crop/resize/scale, linked image movement, undo, and project save. Merge/apply bake coverage exactly once. The editing target and grayscale palette are session UI state.

- Layer hierarchy uses bottom-to-top postorder with descendants before their group header, contiguous subtrees, and validated group parent IDs (maximum eight group levels). Clip stacks stay within one parent, share the lowest unclipped base alpha, and inherit base opacity once. Use source-atop so soft edges do not expand. Group opacity/masks apply once after child compositing. Structural moves carry full clipping stacks; group duplication remaps all descendant IDs.

- Editable text stores content/style/geometry separately from its exact lossless raster cache. Finishing retains editability; only explicit Rasterize, Apply Mask, or merge may discard text metadata. Mask text remains raster painting. Preserve text creation clips and geometry through transforms, duplication, history, and save. Do not round fractional transformed boxes when reopening native input.
- Effect layers process lower siblings within one isolated parent. Use an alpha-mask interpolation for effect strength/coverage rather than source-over, and preserve base alpha for clipped effects. Effects cannot serve as clipping bases. Merge must include any lower input prefix needed by an unclipped effect. Preview sheets must not mutate document state/history before Apply.

- Inspector width is a UI preference, independent of document state/history. Keep the canvas usable when clamping pane sizes; preserve the preferred inspector width through window resizing. Divider drags must preserve zoom, selections, and native inline text drafts/focus.
