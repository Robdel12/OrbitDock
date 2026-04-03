# OrbitDock Memory Interpretation Guide

## Fast Read Sequence
1. Read `capture-summary.txt`.
2. Compare `vmmap-summary.txt` baseline vs post-repro.
3. Check `sample.txt` for active stacks during the spike.
4. Open `allocations.trace` in Instruments for allocation attribution.

## vmmap Heuristics

### Physical footprint
- Treat `Physical footprint` as current real pressure.
- Treat `Physical footprint (peak)` as worst observed pressure.
- Prioritize regressions where peak and current both rise after a repro.

### Region families to watch
- `CoreAnimation`: suspect layer backing store churn, heavy clipping/masking/shadows, or image compositing pressure.
- `CG image` / `Image IO`: suspect image decode/load paths, oversized assets, repeated decode, missing downsampling.
- `MALLOC_SMALL` and `MALLOC metadata`: suspect object churn or fragmentation in app allocations.
- `IOSurface` / `IOAccelerator`: suspect GPU-backed surfaces, large rendered textures, or frequent redraw.

## Stack Pattern Heuristics

### Core Animation image copies
If stacks show `CA::Render::copy_image` or `create_image_by_rendering`, investigate:
- Frequent layer snapshots caused by effects.
- Repeated image-backed layer updates.
- Expensive clipping/shadow combinations around frequently changing views.

### Focus ring rasterization
If stacks show `NSAutomaticFocusRing` and `NSBitmapImageRep` paths, investigate:
- Frequent first-responder churn.
- Focus ring rendering on large/complex views.
- Whether custom focus styling can replace automatic ring rendering for the target view.

## Evidence Quality Checklist
- Capture at least one baseline and one post-repro snapshot.
- Capture the same reproduction path for each run.
- Keep sample windows short (5-10s) around the hotspot.
- Keep allocation traces short (10-20s) for clear attribution.

## Common OrbitDock-Specific Suspects
- Image-heavy conversation rows without downsampling.
- AppKit text or focus transitions that trigger extra raster work.
- Expensive visual chrome on frequently updated ControlDeck or timeline surfaces.

## Useful Follow-up Commands
```bash
heap <PID>
leaks <PID>
xctrace export --input /tmp/orbitdock-alloc.trace --toc
```

Use these only after initial vmmap/sample evidence identifies a likely direction.
