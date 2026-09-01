# OpenTopology

A platform for writing shaders and algorithms that run on a live height map.

OpenTopology is built for a physical AR sandbox (a depth camera and a projector aimed at a box of sand) but it does not need one. The height map can just as easily come from noise, an image, or a recording, so you can build and tune everything on a laptop. Either way you get elevation colors, contour lines, water flowing downhill, routes over the dunes, etc.

## Effects

Effects are written in [Slang](https://shader-slang.org), NVIDIA's shading language, and compiled to WGSL:

```slang
#include "../lib/render.slang"
#include "../lib/color.slang"

[Param(0.05, 0.01, 0.4)] uniform float interval;
[Param(1.5, 0.5, 6.0)]   uniform float width;

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float h = heightSmooth(v.uv);
    float line = contourMask(h, interval, width);
    float3 color = lerp(terrain(h), float3(0.04), line);
    return float4(color * shading(cellOf(v.uv)), 1.0);
}
```

Drop that in `src/effects/` and it shows up in the UI with a slider for every param — no registration, no wiring.

One effect is one file, and that includes the parts that are not shaders. A clustering pass and the shader that paints each cluster live together, because they are the same idea.

## Running it

```sh
npm install
npm run dev
```

Opens a 3D view of the terrain (WebGPU required) with a control panel. Drag to orbit, scroll to zoom, and pick an effect from the dropdown. Every param in the effect becomes a slider.

## How it works

A **source** produces a height frame: noise, an image, a recording, or a Kinect. Effects run over it as a chain of GPU passes. Views render the result: a preview in the panel, and a calibrated top-down image for the projector.

Everything here is a fixed-size grid, so everything runs on the GPU. Connected components is label propagation, shortest paths is wavefront relaxation.

## Sensor

Built against a Kinect for Xbox 360 (model 1414) via `libfreenect`. Nothing in the app requires one — the noise source is the default and needs no hardware.

```sh
npm run kinect:setup
```

That installs `libfreenect` if it is missing and builds `bridge/depth`, a small reader that streams 640x480 uint16 millimetre frames. Plug the Kinect in (it needs its 12V adapter, the bare USB cable will not do), pick **kinect** as the source, and set `basePlane` to the distance from the camera to empty sand and `range` to how far above that you want to fill the height scale.

The dev server pipes frames straight to the page, so there is no second process to start and nothing to configure.

Only one reader can hold the device at a time, so a second dev server or a stray tab will take it over and the other one gets **another reader already has the kinect**. If the sensor stalls instead, the reader resets it over USB and retries, which takes about fifteen seconds before it gives up and asks you to replug.

## Status

Early, but it runs. Animated noise terrain in 3D with three effects. Sensor input, projector output, and calibration are not built yet.

MIT.
