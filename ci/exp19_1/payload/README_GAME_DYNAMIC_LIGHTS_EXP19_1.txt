DarkWolf Experiment 19.1 - Transient / Muzzle Light Isolation
==============================================================

This is a compact test overlay. It intentionally contains no runtime DLLs and no
compiled main game modules. Use it only over the previously working Bloom 18.2
release, which already contains all required system files.

Install
1. Back up the current WolfSP.exe.
2. Extract this package into the existing Bloom 18.2 game directory.
3. Preserve the main folder path for game_dynamic_lights_exp19_1.cfg.
4. Run RUN_GAME_DYNAMIC_LIGHTS_EXP19_1.bat.

Test
1. Load a scene with a nearby wall and select a firearm.
2. Keep the same camera position and wait at least 3 seconds. This allows map
   lights to age out of the transient classifier.
3. Press F6, then F5 once. Wait for CAPTURE_SEQUENCE_COMPLETE.
4. Repeat for F7 through F12 without moving the camera.
5. Exit the game normally and upload the generated ZIP from test_results.

Modes
F6  production reference
F7  all game-authored DXR lights off
F8  persistent/map game lights only
F9  transient candidates only, no shadows
F10 transient lighting-only diagnostic
F11 strong transient-only signal, no shadows
F12 all lights plus prioritized transient candidates and transient shadows

F5 takes a pre-shot image, fires, takes images during the flash, releases attack,
and takes a post-shot image. F4 releases attack manually.

The transient classifier is deliberately diagnostic. A light is considered a
candidate when it appears recently, is close to the camera, and is within a
bounded source radius. Production acceptance requires logs showing
selectedTransient greater than zero during the shot and a local wall response
that is absent in F7/F8.
