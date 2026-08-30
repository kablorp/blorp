// ============================================================================
// blorp Raylib Runtime - Conditionally embedded when raylib is imported
// ============================================================================
//
// This file provides thin wrappers around raylib functions.
// blorp types (long, double) are narrowed to raylib types (int, float, unsigned char).
// Raylib functions are forward-declared to avoid #include <raylib.h>.
//

// ============================================================================
// Forward declarations for raylib types and functions
// ============================================================================

// Raylib Color (4 bytes)
typedef struct { unsigned char r, g, b, a; } __rl_Color;

// Raylib Vector2 (8 bytes)
typedef struct { float x, y; } __rl_Vector2;

// Raylib Rectangle (16 bytes)
typedef struct { float x, y, width, height; } __rl_Rectangle;

// Raylib audio types (must match raylib.h struct layouts exactly)
typedef struct { void *buffer; void *processor; unsigned int sampleRate; unsigned int sampleSize; unsigned int channels; } __rl_AudioStream;
typedef struct { unsigned int frameCount; unsigned int sampleRate; unsigned int sampleSize; unsigned int channels; void *data; } __rl_Wave;
typedef struct { __rl_AudioStream stream; unsigned int frameCount; } __rl_Sound;

// Raylib function forward declarations (C ABI, no mangling)
void InitWindow(int width, int height, const char *title);
void CloseWindow(void);
bool WindowShouldClose(void);
void SetTargetFPS(int fps);
int GetFPS(void);

void BeginDrawing(void);
void EndDrawing(void);
void ClearBackground(__rl_Color color);

void DrawRectangle(int posX, int posY, int width, int height, __rl_Color color);
void DrawRectangleRec(__rl_Rectangle rec, __rl_Color color);
void DrawCircle(int centerX, int centerY, float radius, __rl_Color color);
void DrawLine(int startPosX, int startPosY, int endPosX, int endPosY, __rl_Color color);
void DrawText(const char *text, int posX, int posY, int fontSize, __rl_Color color);
void DrawLineEx(__rl_Vector2 startPos, __rl_Vector2 endPos, float thick, __rl_Color color);
void DrawRectangleRounded(__rl_Rectangle rec, float roundness, int segments, __rl_Color color);
void SetConfigFlags(unsigned int flags);

bool IsKeyPressed(int key);
bool IsKeyDown(int key);
int GetMouseX(void);
int GetMouseY(void);
bool IsMouseButtonPressed(int button);
bool IsMouseButtonDown(int button);

float GetFrameTime(void);
double GetTime(void);

// Audio functions
void InitAudioDevice(void);
void CloseAudioDevice(void);
__rl_Sound LoadSoundFromWave(__rl_Wave wave);
void UnloadWave(__rl_Wave wave);
void UnloadSound(__rl_Sound sound);
void PlaySound(__rl_Sound sound);

// Click sound kits — each has an accent and normal sound
#define NUM_CLICK_KITS 5
static __rl_Sound __click_accents[NUM_CLICK_KITS];
static __rl_Sound __click_normals[NUM_CLICK_KITS];
static int __click_sounds_loaded = 0;
static int __click_kit = 0;  // current kit index

static __rl_Wave __make_wave(int sr, int len) {
    __rl_Wave w;
    memset(&w, 0, sizeof(w));
    w.frameCount = len;
    w.sampleRate = sr;
    w.sampleSize = 16;
    w.channels = 1;
    w.data = malloc(len * 2);
    return w;
}

static void __generate_click_sounds(void) {
    if (__click_sounds_loaded) return;
    int sr = 44100;
    double PI = 3.14159265358979;

    // Kit 0: Classic — crisp sine ping (1500/800 Hz)
    {
        int len = sr / 10;
        __rl_Wave aw = __make_wave(sr, len);
        __rl_Wave nw = __make_wave(sr, len);
        short *ad = (short *)aw.data, *nd = (short *)nw.data;
        for (int i = 0; i < len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 200.0);
            ad[i] = (short)(sin(2*PI*1500*t) * env * 0.9 * 32767);
            nd[i] = (short)(sin(2*PI*800*t) * env * 0.5 * 32767);
        }
        __click_accents[0] = LoadSoundFromWave(aw);
        __click_normals[0] = LoadSoundFromWave(nw);
        UnloadWave(aw); UnloadWave(nw);
    }

    // Kit 1: Woodblock — short, punchy, two harmonics with fast cutoff
    {
        int len = sr / 16;
        __rl_Wave aw = __make_wave(sr, len);
        __rl_Wave nw = __make_wave(sr, len);
        short *ad = (short *)aw.data, *nd = (short *)nw.data;
        for (int i = 0; i < len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 400.0);
            ad[i] = (short)((sin(2*PI*1800*t) + 0.5*sin(2*PI*3600*t)) * env * 0.7 * 32767);
            nd[i] = (short)((sin(2*PI*1200*t) + 0.4*sin(2*PI*2400*t)) * env * 0.45 * 32767);
        }
        __click_accents[1] = LoadSoundFromWave(aw);
        __click_normals[1] = LoadSoundFromWave(nw);
        UnloadWave(aw); UnloadWave(nw);
    }

    // Kit 2: Rimshot — noise burst mixed with a tone, snappy attack
    {
        int len = sr / 12;
        __rl_Wave aw = __make_wave(sr, len);
        __rl_Wave nw = __make_wave(sr, len);
        short *ad = (short *)aw.data, *nd = (short *)nw.data;
        unsigned int rng = 12345;
        for (int i = 0; i < len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 300.0);
            rng = rng * 1103515245 + 12345;
            double noise = ((double)(rng & 0x7FFF) / 16384.0 - 1.0);
            ad[i] = (short)((0.6*sin(2*PI*900*t) + 0.4*noise) * env * 0.85 * 32767);
            nd[i] = (short)((0.5*sin(2*PI*600*t) + 0.3*noise) * env * 0.5 * 32767);
        }
        __click_accents[2] = LoadSoundFromWave(aw);
        __click_normals[2] = LoadSoundFromWave(nw);
        UnloadWave(aw); UnloadWave(nw);
    }

    // Kit 3: Cowbell — two detuned tones, longer ring
    {
        int len = sr / 6;
        __rl_Wave aw = __make_wave(sr, len);
        __rl_Wave nw = __make_wave(sr, len);
        short *ad = (short *)aw.data, *nd = (short *)nw.data;
        for (int i = 0; i < len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 80.0);
            ad[i] = (short)((0.6*sin(2*PI*587*t) + 0.4*sin(2*PI*845*t)) * env * 0.8 * 32767);
            nd[i] = (short)((0.6*sin(2*PI*587*t) + 0.4*sin(2*PI*845*t)) * env * 0.4 * 32767);
        }
        __click_accents[3] = LoadSoundFromWave(aw);
        __click_normals[3] = LoadSoundFromWave(nw);
        UnloadWave(aw); UnloadWave(nw);
    }

    // Kit 4: Hi-hat — filtered noise, open hat for accent, closed for normal
    {
        int acc_len = sr / 5;   // open hat: longer
        int norm_len = sr / 14; // closed hat: short
        __rl_Wave aw = __make_wave(sr, acc_len);
        __rl_Wave nw = __make_wave(sr, norm_len);
        short *ad = (short *)aw.data, *nd = (short *)nw.data;
        unsigned int rng = 67890;
        for (int i = 0; i < acc_len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 25.0);
            rng = rng * 1103515245 + 12345;
            double noise = ((double)(rng & 0x7FFF) / 16384.0 - 1.0);
            // Bandpass-ish: mix two high tones with noise
            double sample = 0.3*sin(2*PI*6500*t) + 0.3*sin(2*PI*8200*t) + 0.4*noise;
            ad[i] = (short)(sample * env * 0.7 * 32767);
        }
        rng = 67890;
        for (int i = 0; i < norm_len; i++) {
            double t = (double)i / sr;
            double env = exp(-t * 200.0);
            rng = rng * 1103515245 + 12345;
            double noise = ((double)(rng & 0x7FFF) / 16384.0 - 1.0);
            double sample = 0.3*sin(2*PI*6500*t) + 0.3*sin(2*PI*8200*t) + 0.4*noise;
            nd[i] = (short)(sample * env * 0.5 * 32767);
        }
        __click_accents[4] = LoadSoundFromWave(aw);
        __click_normals[4] = LoadSoundFromWave(nw);
        UnloadWave(aw); UnloadWave(nw);
    }

    __click_sounds_loaded = 1;
}

// ============================================================================
// Conversion helpers
// ============================================================================

static inline __rl_Color __blorp_to_rl_color(Color c) {
    __rl_Color rc;
    rc.r = (unsigned char)c.r;
    rc.g = (unsigned char)c.g;
    rc.b = (unsigned char)c.b;
    rc.a = (unsigned char)c.a;
    return rc;
}

static inline __rl_Vector2 __blorp_to_rl_vec2(Vector2 v) {
    __rl_Vector2 rv;
    rv.x = (float)v.x;
    rv.y = (float)v.y;
    return rv;
}

static inline __rl_Rectangle __blorp_to_rl_rect(Rectangle r) {
    __rl_Rectangle rr;
    rr.x = (float)r.x;
    rr.y = (float)r.y;
    rr.width = (float)r.width;
    rr.height = (float)r.height;
    return rr;
}

// ============================================================================
// Window management wrappers
// ============================================================================

void blorp_raylib_init_window(long width, long height, blorp_String *title) {
    InitWindow((int)width, (int)height, title->data);
}

void blorp_raylib_close_window(void) {
    CloseWindow();
}

bool blorp_raylib_window_should_close(void) {
    return WindowShouldClose();
}

void blorp_raylib_set_target_fps(long fps) {
    SetTargetFPS((int)fps);
}

long blorp_raylib_get_fps(void) {
    return (long)GetFPS();
}

// ============================================================================
// Drawing wrappers
// ============================================================================

void blorp_raylib_begin_drawing(void) {
    BeginDrawing();
}

void blorp_raylib_end_drawing(void) {
    EndDrawing();
}

void blorp_raylib_clear_background(Color color) {
    ClearBackground(__blorp_to_rl_color(color));
}

// ============================================================================
// Shape drawing wrappers
// ============================================================================

void blorp_raylib_draw_rectangle(long x, long y, long w, long h, Color color) {
    DrawRectangle((int)x, (int)y, (int)w, (int)h, __blorp_to_rl_color(color));
}

void blorp_raylib_draw_rectangle_rec(Rectangle rec, Color color) {
    DrawRectangleRec(__blorp_to_rl_rect(rec), __blorp_to_rl_color(color));
}

void blorp_raylib_draw_circle(long cx, long cy, double radius, Color color) {
    DrawCircle((int)cx, (int)cy, (float)radius, __blorp_to_rl_color(color));
}

void blorp_raylib_draw_line(long x1, long y1, long x2, long y2, Color color) {
    DrawLine((int)x1, (int)y1, (int)x2, (int)y2, __blorp_to_rl_color(color));
}

void blorp_raylib_draw_text(blorp_String *text, long x, long y, long font_size, Color color) {
    DrawText(text->data, (int)x, (int)y, (int)font_size, __blorp_to_rl_color(color));
}

void blorp_raylib_draw_line_thick(long x1, long y1, long x2, long y2, double thick, Color color) {
    __rl_Vector2 start = {(float)x1, (float)y1};
    __rl_Vector2 end = {(float)x2, (float)y2};
    DrawLineEx(start, end, (float)thick, __blorp_to_rl_color(color));
}

void blorp_raylib_draw_rectangle_rounded(Rectangle rec, double roundness, long segments, Color color) {
    DrawRectangleRounded(__blorp_to_rl_rect(rec), (float)roundness, (int)segments, __blorp_to_rl_color(color));
}

void blorp_raylib_set_config_flags(long flags) {
    SetConfigFlags((unsigned int)flags);
}

// ============================================================================
// Input wrappers
// ============================================================================

bool blorp_raylib_is_key_pressed(long key) {
    return IsKeyPressed((int)key);
}

bool blorp_raylib_is_key_down(long key) {
    return IsKeyDown((int)key);
}

long blorp_raylib_get_mouse_x(void) {
    return (long)GetMouseX();
}

long blorp_raylib_get_mouse_y(void) {
    return (long)GetMouseY();
}

bool blorp_raylib_is_mouse_button_pressed(long button) {
    return IsMouseButtonPressed((int)button);
}

bool blorp_raylib_is_mouse_button_down(long button) {
    return IsMouseButtonDown((int)button);
}

// ============================================================================
// Timing wrappers
// ============================================================================

double blorp_raylib_get_frame_time(void) {
    return (double)GetFrameTime();
}

double blorp_raylib_get_time(void) {
    return GetTime();
}

// ============================================================================
// Audio wrappers
// ============================================================================

void blorp_raylib_init_audio(void) {
    InitAudioDevice();
    __generate_click_sounds();
}

void blorp_raylib_close_audio(void) {
    if (__click_sounds_loaded) {
        for (int i = 0; i < NUM_CLICK_KITS; i++) {
            UnloadSound(__click_accents[i]);
            UnloadSound(__click_normals[i]);
        }
        __click_sounds_loaded = 0;
    }
    CloseAudioDevice();
}

void blorp_raylib_play_click(long accent) {
    if (!__click_sounds_loaded) return;
    if (accent) {
        PlaySound(__click_accents[__click_kit]);
    } else {
        PlaySound(__click_normals[__click_kit]);
    }
}

void blorp_raylib_set_click_kit(long kit) {
    if (kit >= 0 && kit < NUM_CLICK_KITS) __click_kit = (int)kit;
}

long blorp_raylib_get_num_click_kits(void) {
    return NUM_CLICK_KITS;
}
