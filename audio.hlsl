#define pi 3.1415926535

#define R12_2 1.0594630943592953

#define A9 A8 * 2
#define A8 A7 * 2
#define A7 A6 * 2
#define A6 A5 * 2
#define A5 A4 * 2
#define A4 440.00
#define A3 A4 / 2
#define A2 A3 / 2
#define A1 A2 / 2
#define A0 A1 / 2

#define As9 As8 * 2
#define As8 As7 * 2
#define As7 As6 * 2
#define As6 As5 * 2
#define As5 As4 * 2
#define As4 466.16
#define As3 As4 / 2
#define As2 As3 / 2
#define As1 As2 / 2
#define As0 As1 / 2

#define Bb9 As9
#define Bb8 As8
#define Bb7 As7
#define Bb6 As6
#define Bb5 As5
#define Bb4 As4
#define Bb3 As3
#define Bb2 As2
#define Bb1 As1
#define Bb0 As0

#define B9 B8 * 2
#define B8 B7 * 2
#define B7 B6 * 2
#define B6 B5 * 2
#define B5 B4 * 2
#define B4 493.88
#define B3 B4 / 2
#define B2 B3 / 2
#define B1 B2 / 2
#define B0 B1 / 2

#define C9 C8 * 2
#define C8 C7 * 2
#define C7 C6 * 2
#define C6 C5 * 2
#define C5 C4 * 2
#define C4 261.63
#define C3 C4 / 2
#define C2 C3 / 2
#define C1 C2 / 2
#define C0 C1 / 2

#define Cs9 Cs8 * 2
#define Cs8 Cs7 * 2
#define Cs7 Cs6 * 2
#define Cs6 Cs5 * 2
#define Cs5 Cs4 * 2
#define Cs4 277.18
#define Cs3 Cs4 / 2
#define Cs2 Cs3 / 2
#define Cs1 Cs2 / 2
#define Cs0 Cs1 / 2

#define Db9 Cs9
#define Db8 Cs8
#define Db7 Cs7
#define Db6 Cs6
#define Db5 Cs5
#define Db4 Cs4
#define Db3 Cs3
#define Db2 Cs2
#define Db1 Cs1
#define Db0 Cs0

#define D9 D8 * 2
#define D8 D7 * 2
#define D7 D6 * 2
#define D6 D5 * 2
#define D5 D4 * 2
#define D4 293.66
#define D3 D4 / 2
#define D2 D3 / 2
#define D1 D2 / 2
#define D0 D1 / 2

#define Ds9 Ds8 * 2
#define Ds8 Ds7 * 2
#define Ds7 Ds6 * 2
#define Ds6 Ds5 * 2
#define Ds5 Ds4 * 2
#define Ds4 311.13
#define Ds3 Ds4 / 2
#define Ds2 Ds3 / 2
#define Ds1 Ds2 / 2
#define Ds0 Ds1 / 2

#define Eb9 Ds9
#define Eb8 Ds8
#define Eb7 Ds7
#define Eb6 Ds6
#define Eb5 Ds5
#define Eb4 Ds4
#define Eb3 Ds3
#define Eb2 Ds2
#define Eb1 Ds1
#define Eb0 Ds0

#define E9 E8 * 2
#define E8 E7 * 2
#define E7 E6 * 2
#define E6 E5 * 2
#define E5 E4 * 2
#define E4 329.63
#define E3 E4 / 2
#define E2 E3 / 2
#define E1 E2 / 2
#define E0 E1 / 2

#define F9 F8 * 2
#define F8 F7 * 2
#define F7 F6 * 2
#define F6 F5 * 2
#define F5 F4 * 2
#define F4 349.23
#define F3 F4 / 2
#define F2 F3 / 2
#define F1 F2 / 2
#define F0 F1 / 2

#define Fs9 Fs8 * 2
#define Fs8 Fs7 * 2
#define Fs7 Fs6 * 2
#define Fs6 Fs5 * 2
#define Fs5 Fs4 * 2
#define Fs4 369.99
#define Fs3 Fs4 / 2
#define Fs2 Fs3 / 2
#define Fs1 Fs2 / 2
#define Fs0 Fs1 / 2

#define Gb9 Fs9
#define Gb8 Fs8
#define Gb7 Fs7
#define Gb6 Fs6
#define Gb5 Fs5
#define Gb4 Fs4
#define Gb3 Fs3
#define Gb2 Fs2
#define Gb1 Fs1
#define Gb0 Fs0

#define G9 G8 * 2
#define G8 G7 * 2
#define G7 G6 * 2
#define G6 G5 * 2
#define G5 G4 * 2
#define G4 392.00
#define G3 G4 / 2
#define G2 G3 / 2
#define G1 G2 / 2
#define G0 G1 / 2

#define Gs9 Gs8 * 2
#define Gs8 Gs7 * 2
#define Gs7 Gs6 * 2
#define Gs6 Gs5 * 2
#define Gs5 Gs4 * 2
#define Gs4 415.30
#define Gs3 Gs4 / 2
#define Gs2 Gs3 / 2
#define Gs1 Gs2 / 2
#define Gs0 Gs1 / 2

#define Ab9 Gs9
#define Ab8 Gs8
#define Ab7 Gs7
#define Ab6 Gs6
#define Ab5 Gs5
#define Ab4 Gs4
#define Ab3 Gs3
#define Ab2 Gs2
#define Ab1 Gs1
#define Ab0 Gs0

[[vk::binding(0, 0)]]
RWStructuredBuffer<float> rendered_audio;

[[vk::binding(1, 0)]]
cbuffer Uniforms {
    uint u_cpu_read_ptr;
    uint u_seek;
    bool u_paused;
    uint u_sample_frequency;

    uint3 u_dispatch_dimensions;

    uint4 u_sequence0;
    uint4 u_sequence1;
    uint4 u_sequence2;

    uint4 u_counters;
    uint u_input_track_count;
};

[[vk::binding(2, 0)]]
[[vk::image_format("bgra8")]]
RWTexture2D<float4> render_target;

[[vk::binding(3, 0)]]
RWStructuredBuffer<float> input_tracks[];

#define group_dimensions uint3(32, 32, 1)

uint sample(uint track, uint seek, out float2 stereo) {
    if (track >= u_input_track_count) {
        stereo = float2(0.0, 0.0);
        return 0xffffffff;
    }

    uint _, count;
    input_tracks[track].GetDimensions(count, _);

    uint rem = (seek * 2) / count;
    uint s = (seek * 2) % count;
    stereo = float2(input_tracks[track][s + 0], input_tracks[track][s + 1]);
    return rem;
}

uint sample(uint track, uint seek, out float2 stereo, uint loop_count) {
    float2 s = 0.0;
    uint rem = sample(track, seek, s);
    if (rem <= loop_count) {
        stereo = s;
    }

    return rem;
}

uint samplef(uint track, float t, out float2 stereo) {
    return sample(track, uint(t * u_sample_frequency), stereo);
}

uint samplef(uint track, float t, out float2 stereo, uint loop_count) {
    float2 s = 0.0;
    uint rem = samplef(track, t, s);
    if (rem <= loop_count) {
        stereo = s;
    }

    return rem;
}

uint resample(uint track, uint seek, out float2 stereo, float speed) {
    float new_seek = seek * speed;
    uint low_seek = uint(new_seek);
    uint high_seek = low_seek + 1;
    float diff = new_seek - low_seek;

    float2 low_stereo, high_stereo;
    uint low_rem = sample(track, low_seek, low_stereo);
    uint high_rem = sample(track, high_seek, high_stereo);

    stereo = low_stereo + (high_stereo - low_stereo) * diff;
    return high_rem;
}

uint resample(uint track, uint seek, out float2 stereo, uint loop_count, float speed) {
    float2 s = 0.0;
    uint rem = resample(track, seek, s, speed);
    if (rem <= loop_count) {
        stereo = s;
    }

    return rem;
}

uint resample_ex(uint track, uint base, uint offset, out float2 stereo, float speed) {
    float new_seek = base + offset * speed;
    uint low_seek = uint(new_seek);
    uint high_seek = low_seek + 1;
    float diff = new_seek - low_seek;

    float2 low_stereo, high_stereo;
    uint low_rem = sample(track, low_seek, low_stereo);
    uint high_rem = sample(track, high_seek, high_stereo);

    stereo = low_stereo + (high_stereo - low_stereo) * diff;
    return high_rem;
}

uint resample_ex(uint track, uint base, uint offset, out float2 stereo, uint loop_count, float speed) {
    float2 s = 0.0;
    uint rem = resample_ex(track, base, offset, s, speed);
    if (rem <= loop_count) {
        stereo = s;
    }

    return rem;
}

uint resamplef(uint track, float t, out float2 stereo, float speed) {
    return resample(track, uint(t * u_sample_frequency), stereo, speed);
}

uint resamplef(uint track, float t, out float2 stereo, uint loop_count, float speed) {
    float2 s = 0.0;
    uint rem = resamplef(track, t, s, speed);
    if (rem <= loop_count) {
        stereo = s;
    }

    return rem;
}

void render(uint seek, float2 stereo) {
    uint _, count;
    rendered_audio.GetDimensions(count, _);
    
    if (seek >= count) {
        return;
    }

    rendered_audio[seek * 2 + 0] = stereo.x;
    rendered_audio[seek * 2 + 1] = stereo.y;
}

float sine_wave(float t, float frequency) {
    return sin(2 * pi * t * frequency);
}

float square_wave(float t, float frequency) {
    return sign(sine_wave(t, frequency));
}

float saw_wave(float t, float frequency) {
    return ((t * frequency) % 1) * 2 - 1;
}

float piano(float t, float f, float decay) {
    if (t < 0) {
        return 0.0;
    }

    float m = sine_wave(t, f) * exp(decay * 2 * pi * f * t);
    m += sine_wave(2 * t, f) * exp(decay * 2 * pi * f * t) / 2;
    m += sine_wave(3 * t, f) * exp(decay * 2 * pi * f * t) / 4;
    m += sine_wave(4 * t, f) * exp(decay * 2 * pi * f * t) / 8;
    m += sine_wave(5 * t, f) * exp(decay * 2 * pi * f * t) / 16;
    m += sine_wave(6 * t, f) * exp(decay * 2 * pi * f * t) / 32;
    return (m + m * m * m) * (1 + 16 * t * exp(-6 * t)) / 6.0;
}

float quantize(float m, uint steps) {
    return float(uint(clamp(m, 0.0, 1.0) * float(steps - 1) + 0.5)) / float(steps - 1);
}

float2 quantize(float2 stereo, uint steps) {
    return float2(quantize(stereo.x, steps), quantize(stereo.y, steps));
}

float cquantize(float m, uint steps) {
    return quantize((m + 1.0) / 2.0, steps) * 2.0 - 1.0;
}

float2 cquantize(float2 stereo, uint steps) {
    return float2(cquantize(stereo.x, steps), cquantize(stereo.y, steps));
}

float bpm_to_frequency(float bpm) {
    return bpm / 60;
}

float beattime(float bpm) {
    return 60 / bpm;
}

float bpm_to_period(float bpm) {
    return beattime(bpm);
}

float measuretime(float bpm, float ts) {
    return beattime(bpm) * ts;
}

float periodic(float t, float frequency) {
    return t % (1 / frequency);
}

float periodic_bpm(float t, float bpm) {
    return periodic(t, bpm_to_frequency(bpm));
}

float periodic_beats(float t, float bpm, float beats) {
    return periodic_bpm(t, bpm / beats);
}

float click(float t, float f) {
    float s1 = 8 * exp(-80.0 * t) * sine_wave(t, f);
    float s2 = 4.5 * exp(-125.0 * t) * sine_wave(t, 2.8 * f);
    float s3 = 3 * exp(-160.0 * t) * sine_wave(t, 5.5 * f);
    float s4 = 2 * exp(-200.0 * t) * sine_wave(t, 9.0 * f);

    return s1 + s2 + s3 + s4;
}

void display(uint id, float2 stereo) {
    uint2 rt_dimensions;
    render_target.GetDimensions(rt_dimensions.x, rt_dimensions.y);

    uint dsize = group_dimensions.x * group_dimensions.y * group_dimensions.z;
    float aspect = rt_dimensions.x / float(dsize);
    uint xcoord = float(id) * aspect;
    uint pixel_size = 2;
    for (uint y = 0; y < pixel_size; ++y) {
        for (uint x = 0; x < pixel_size; ++x) {
            render_target[uint2(xcoord, rt_dimensions.y / 2 - rt_dimensions.y / 4 + stereo.x * rt_dimensions.y / 4) + uint2(x, y)] = float4(0.0, 0.0, 1.0, 1.0);
            render_target[uint2(xcoord, rt_dimensions.y / 2 + rt_dimensions.y / 4 + stereo.y * rt_dimensions.y / 4) + uint2(x, y)] = float4(1.0, 0.0, 0.0, 1.0);
        }
    }
}

float2 stereo(float m) {
    return float2(m, m);
}

float2 mix(float2 a, float2 b, float2 levels) {
    return a * levels.x + b * levels.y;
}

float rand(float t) {
    return 0.0;
}

float rounded_square_wave(float t, float f) {
    return clamp(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(2 * pi * t * f))))))))))) / 0.43, -1.0, 1.0);
}

uint sequence(uint i) {
    i = clamp(i, 0, 11);

    uint4 sequence;
    if (i / 4 == 0) {
        sequence = u_sequence0;
    } else if (i / 4 == 1) {
        sequence = u_sequence1;
    } else if (i / 4 == 2) {
        sequence = u_sequence2;
    }

    if (i % 4 == 0) {
        return sequence.x;
    } else if (i % 4 == 1) {
        return sequence.y;
    } else if (i % 4 == 2) {
        return sequence.z;
    }

    return sequence.w;
}

float sequencef(uint i) {
    uint s = sequence(i);
    return float(s) / float(u_sample_frequency);
}

uint counter(uint i) {
    i = clamp(i, 0, 7);

    uint word;
    uint wi = i / 2;
    if (wi == 0) {
        word = u_counters.x;
    } else if (wi == 1) {
        word = u_counters.y;
    } else if (wi == 2) {
        word = u_counters.z;
    } else {
        word = u_counters.w;
    }

    if (i % 2 == 0) {
        return word & 0xffff;
    } else {
        return word >> 16;
    }
}

float decay(float t, float p) {
    if (t < 0.0) {
        return 0.0;
    }

    return exp(t * p);
}

float2 s(float t, uint i, float f, float d) {
    //return stereo(rounded_square_wave(t - sequencef(i), f) * decay(t - sequencef(i), d));
    return stereo(piano(t - sequencef(i), f, d));
}

float2 stab(float t, float bpm) {
    float3 map[] = {
        float3(00.00, 0.50, As3),
        float3(00.75, 0.50, As3),
        float3(01.50, 0.50, As3),
        float3(02.50, 0.50, As3),
        float3(03.50, 0.50, As3),

        float3(04.00, 0.50, F3),
        float3(04.75, 0.50, F3),
        float3(05.50, 0.50, F3),
        float3(06.50, 0.50, F3),
        float3(07.50, 0.50, F3),

        float3(08.00, 0.50, Ds3),
        float3(08.75, 0.50, Ds3),
        float3(09.50, 0.50, Ds3),
        float3(10.50, 0.50, Ds3),
        //float3(11.50, 0.50, Ds3),

        float3(12.00, 0.50, Ds3),
        float3(12.75, 0.50, Ds3),
        float3(13.50, 0.50, Ds3),
        float3(14.50, 0.50, Ds3),
        //float3(15.50, 0.50, Ds3),

        float3(16.00, 0.50, As3),
        float3(16.75, 0.50, As3),
        float3(17.50, 0.50, As3),
        float3(18.50, 0.50, As3),
        float3(19.50, 0.50, As3),

        float3(20.00, 0.50, F3),
        float3(20.75, 0.50, F3),
        float3(21.50, 0.50, F3),
        //float3(22.50, 0.50, F3),
        float3(23.50, 0.50, F3),

        float3(24.00, 0.50, Ds3),
        float3(24.75, 0.50, Ds3),
        float3(25.50, 0.50, Ds3),
        float3(26.50, 0.50, Ds3),
        float3(27.50, 0.50, Ds3),

        float3(28.00, 0.50, Ds3),
        float3(28.75, 0.50, Ds3),
        float3(29.50, 0.50, Ds3),
        //float3(30.50, 0.50, Ds3),
        float3(31.50, 0.50, Ds3),
    };

    float2 final;
    float pt = t % measuretime(bpm, 4 * 8);
    for (uint i = 0; i < sizeof(map) / sizeof(map[0]); ++i) {
        float st = map[i].x * beattime(bpm);
        float hold = map[i].y * beattime(bpm);
        float tt = pt - st;
        if (pt < st || tt > hold) {
            continue;
        }

        float2 sl, sr;
        resamplef(0, tt, sl, 0, map[i].z / C5);
        resamplef(0, tt + 0.01, sr, 0, map[i].z / C5);

        final = float2(0.75, 0.25) * sl + float2(0.25, 0.75) * sr;
    }

    return final * float2(1.0, 1.0);
}

float2 metronome(float t, float bpm) {
    float pt = t % measuretime(bpm, 4);
    float tt = pt % beattime(bpm);

    float2 final;
    if (pt < beattime(bpm)) {
        samplef(1, tt, final, 0);
    } else {
        resamplef(1, tt, final, 0, pow(2.0, -7.0 / 12.0));
    }

    return final;
}

float2 instrument(uint id, uint n, float t) {
    float2 final;
    for (uint i = 0; i < 12; i++) {
        uint si = sequence(i);
        if (si == 0xffffffff) {
            continue;
        }

        float2 s;
        resample((int(counter(3)) - int(counter(2))) % u_input_track_count, n - si, s, 0, pow(2.0, i / 12.0) * pow(2.0, float(counter(1)) - counter(0)));

        final += s;
    }

    return final;
}

float2 clap(float t, float bpm) {
    float2 map[] = {
        float2(1.00, 1.00),
        float2(3.00, 1.00),
    };

    float2 final;
    float pt = t % measuretime(bpm, 4);
    for (uint i = 0; i < sizeof(map) / sizeof(map[0]); ++i) {
        float st = map[i].x * beattime(bpm);
        float hold = map[i].y * beattime(bpm);
        float tt = pt - st;
        if (pt < st || tt > hold) {
            continue;
        }

        float2 sl, sr;
        samplef(3, tt, sl, 0);
        samplef(3, tt + 0.00005, sr, 0);

        final = 0.75 * sl + 0.25 * sr;
    }

    return final * float2(1.0, 1.0);
}

float2 kick(float t, float bpm) {
    float2 map[] = {
        float2(00.00, 0.50),
        float2(02.50, 0.50),

        float2(04.00, 0.50),
        float2(06.50, 0.50),

        float2(08.00, 0.50),
        float2(10.50, 0.50),
        float2(11.50, 0.50),

        float2(12.00, 0.50),
        float2(14.50, 0.50),
    };

    float2 final;
    float pt = t % measuretime(bpm, 4 * 4);
    for (uint i = 0; i < sizeof(map) / sizeof(map[0]); ++i) {
        float st = map[i].x * beattime(bpm);
        float hold = map[i].y * beattime(bpm);
        float tt = pt - st;
        if (pt < st || tt > hold) {
            continue;
        }

        float2 s;
        samplef(2, tt, s, 0);

        final += s;
    }

    return final;
}

float2 sample_kit(uint id, uint n, float t) {
    float2 final;
    for (uint i = 0; i < 12; i++) {
        uint si = sequence(i);
        if (si == 0xffffffff) {
            continue;
        }

        float2 s;
        sample(i + (int(counter(3)) - int(counter(2))) % u_input_track_count, n - si, s, 0);

        final += s;
    }

    return final;
}

void audio(uint id, uint n, float t) {
    float bpm = 130;
    float2 instr = instrument(id, n, t);
    float2 skit = sample_kit(id, n, t);
    float2 percussion = 1.0 * kick(t, bpm) + 0.65 * clap(t, bpm);
    float2 song = 0.4 * stab(t, bpm) + 1.15 * metronome(t, bpm) + percussion;

    //float2 final = mix(mix(skit, instr, float2(counter(4) % 2 == 0, counter(4) % 2 == 1)), song, float2(1 + (int(counter(7)) - int(counter(6))) / 20.0, counter(5) % 2 == 0));
    //final = kick(t, bpm) + clap(t, bpm);
    float2 final = clamp(song, -1.0, 1.0);

    render(id, final);
    display(id, final);
}

[numthreads(32, 32, 1)]
void process_audio(
    uint3 group_id : SV_GroupID,
    uint3 group_thread_id : SV_GroupThreadID,
    uint3 thread_coordinate_id : SV_DispatchThreadID
) {
    uint id = group_thread_id.x + group_dimensions.x * (group_thread_id.y + group_dimensions.y * (group_thread_id.z + group_dimensions.z * (group_id.x + u_dispatch_dimensions.x * (group_id.y + u_dispatch_dimensions.y * group_id.z))));
    uint n = id + u_seek;
    float t = float(n) / float(u_sample_frequency);

    audio(id, n, t);
}
