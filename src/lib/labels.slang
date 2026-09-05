#ifndef OT_LABELS
#define OT_LABELS

#include "field.slang"

static const uint MAX_LABELS = 64;

static const uint UNIT_NONE = 0;
static const uint UNIT_MM = 1;
static const uint UNIT_CM2 = 2;
static const uint UNIT_ML = 3;
static const uint UNIT_MM_S = 4;
static const uint UNIT_DEG = 5;

static const uint TAG_NONE = 0;
static const uint TAG_L = 1;
static const uint TAG_W = 2;
static const uint TAG_H = 3;
static const uint TAG_R = 4;
static const uint TAG_IMPACT = 5;
static const uint UNIT_COUNT = 6;
static const uint UNIT_PERCENT = 7;

struct Label {
    float2 cell;
    float height;
    float value;
    uint unit;
    uint line;
    uint shown;
    uint tag;
};

#endif
