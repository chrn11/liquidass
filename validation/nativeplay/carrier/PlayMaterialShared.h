#ifndef PLAY_MATERIAL_SHARED_H
#define PLAY_MATERIAL_SHARED_H

// One bounded screen-space material contract shared by native CPU checks and MSL.
#define PLAY_INPUT_WIDTH 480.0f
#define PLAY_INPUT_HEIGHT 360.0f
#define PLAY_CENTER_X (PLAY_INPUT_WIDTH * 0.5f)
#define PLAY_CENTER_Y (PLAY_INPUT_HEIGHT * 0.5f)

// Candidate-11 capsule: 272 x 144 logical px, radius 72 (1.89:1).
#define PLAY_CAPSULE_HALF_WIDTH 136.0f
#define PLAY_CAPSULE_HALF_HEIGHT 72.0f
#define PLAY_CAPSULE_RADIUS 72.0f
#define PLAY_CAPSULE_STRAIGHT_HALF (PLAY_CAPSULE_HALF_WIDTH - PLAY_CAPSULE_RADIUS)

// Rounded transverse dome continuously tapered along the major axis.
#define PLAY_DOME_RADIUS 72.0f
#define PLAY_DOME_STRAIGHT_HALF (PLAY_CAPSULE_HALF_WIDTH - PLAY_DOME_RADIUS)
#define PLAY_AXIAL_RADIUS 150.0f
#define PLAY_DOME_REGULARIZER 0.16f
#define PLAY_HEIGHT_BEZEL_GAIN 1.2f
#define PLAY_HEIGHT_THICKNESS_GAIN 1.0f
#define PLAY_HEIGHT_MAX_PX 40.0f
#define PLAY_PATH_FADE_HEIGHT_PX 10.0f
#define PLAY_TRANSPORT_SLOPE_SCALE 0.82f
#define PLAY_VIRTUAL_IMAGE_GAP_PX 88.0f

// Strict radial cap: less than 28 px, ~19.4% of this 144 px body height.
#define PLAY_REFRACTION_LIMIT_PX 28.0f
// UV debug maps [-28,+28] px per component into linear [0,1].
#define PLAY_UV_DECODE_SCALE (2.0f * PLAY_REFRACTION_LIMIT_PX)
#define PLAY_UV_QUANTIZATION_ALLOWANCE_PX 0.30f

#endif
