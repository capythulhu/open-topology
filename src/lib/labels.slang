#ifndef OT_LABELS
#define OT_LABELS

#include "field.slang"

// Text the runtime draws over the view. An effect fills a [Labels] buffer of
// these on the GPU; the runtime reads it back, projects each anchor with the same
// camera as the shaders, and letters value + unit beside it. Entries with the
// same anchor and increasing line stack downwards.

static const uint MAX_LABELS = 64;

static const uint UNIT_NONE = 0;
static const uint UNIT_MM = 1;
static const uint UNIT_CM2 = 2;
static const uint UNIT_ML = 3;
static const uint UNIT_MM_S = 4;
static const uint UNIT_DEG = 5;
static const uint UNIT_COUNT = 6;

struct Label {
    float2 cell;
    float height;
    float value;
    uint unit;
    uint line;
    uint shown;
    uint reserved;
};

#endif
