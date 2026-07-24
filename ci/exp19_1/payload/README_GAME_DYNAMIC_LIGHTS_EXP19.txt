DarkWolf Game Dynamic Lights Bridge Experiment 19
=================================================

BASE PRESERVED
Stable Clear v2.2
+ Real Mipmaps
+ Polygon Offset
+ Dynamic Light Quality 14
+ Atmospheric Fog 15.1
+ Material-Aware Specular/Roughness 16 R3
+ HDR-Like Tone Mapping 17
+ Dual-Source Multi-Scale Bloom 18.2

WHAT EXPERIMENT 19 CHANGES
- Replaces the primitive game-light submission block with a controlled bridge.
- Adds independent strength and radius controls for RTCW-authored transient lights.
- Adds a game-light-only shadow switch without disabling fallback or rect-light shadows.
- Adds one-second runtime diagnostics proving whether the game submits lights.
- Does not change mipmaps, polygon offset, fog, material classification, tone mapping or Bloom.

NEW CVARS
r_dxrGameDynamicLights 0/1
r_dxrGameDynamicLightStrength 0.0..8.0
r_dxrGameDynamicLightRadiusScale 0.05..4.0
r_dxrGameDynamicLightShadows 0/1
r_dxrGameDynamicLightDebug 0/1

TEST
1. Copy/extract the artifact into a separate RTCW working directory.
2. Run RUN_GAME_DYNAMIC_LIGHTS_EXP19.bat.
3. Load a save, select a firearm and stand close to a wall.
4. Keep the same position.
5. Press F6, fire repeatedly for 4-6 seconds, then repeat through F12.
6. Exit normally.
7. Upload the newest test_results/GAME_DYNAMIC_LIGHTS_EXP19_*.zip.

The collector automatically saves a 12-frame burst after every F6-F12 press,
plus rtcwconsole.log, bridge diagnostics and a summary.
