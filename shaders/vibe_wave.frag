// Vibe V3 — порт десктопного WebGL-шейдера (vibe-worker.js, rev 27)
// под Flutter FragmentShader (flutter_shaders).
//
// Источник: C:\kumaflow-pc-new\src\features\wave\vibe-worker.js
// domain warping + fbm noise + радиальные лучи + неон + огненные угли.
// Звук подаётся снаружи униформами (uEnergy/uBeat), анализатора как в Web
// Audio на мобиле нет — пульс считается от BPM трека.
#include <flutter/runtime_effect.glsl>

uniform vec2 uRes;
uniform float uTime;
uniform float uHue;
uniform vec3 uBg;
uniform float uIntensity;
uniform float uSoftness;
uniform float uScale;
uniform float uRays;
uniform float uNeon;
uniform float uBend;
uniform float uEnergy;
uniform float uBeat;
uniform float uScream;
uniform float uFxFire;

out vec4 fragColor;

/* --- simplex noise 2D (Ashima Arts / Stefan Gustavson, MIT) --- */
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x * 34.0) + 1.0) * x); }

float snoise(vec2 v) {
  const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                     -0.577350269189626, 0.024390243902439);
  vec2 i  = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy -= i1;
  i = mod289(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
                        + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m;
  m = m * m;
  vec3 x  = 2.0 * fract(p * C.www) - 1.0;
  vec3 h  = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
  vec3 g;
  g.x  = a0.x * x0.x + h.x * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
  for (int i = 0; i < 3; i++) {
    v += a * snoise(p);
    p = rot * p * 2.02;
    a *= 0.5;
  }
  return v;
}

vec3 hue2rgb(float h) {
  vec3 p = abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
  return clamp(p - 1.0, 0.0, 1.0);
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  float t = uTime;
  vec2 drift = vec2(sin(t * 0.11) + sin(t * 0.043 + 1.7),
                    cos(t * 0.13) + cos(t * 0.051 + 0.6)) * 0.035;
  vec2 uv = (fragCoord - 0.5 * uRes) / min(uRes.x, uRes.y) - drift;
  uv.x *= 0.85;
  float et = 1.0;
  float morph = 0.5 + 0.5 * sin(t * 0.2618 + 1.0);
  float star = smoothstep(0.45, 0.85, morph);
  float loopGate = smoothstep(0.2, 0.8, 0.5 + 0.5 * sin(t * 0.21 + 2.0));
  float breath = 1.0 + 0.05 * sin(t * 0.9) + uBeat * 0.045;
  float eCl = clamp(uEnergy, 0.0, 1.0);
  float bgL = clamp(dot(uBg, vec3(0.3333)), 0.0, 1.0);

  float sizeK = mix(1.45, 0.65, clamp((uScale - 0.4) / 1.8, 0.0, 1.0));
  vec2 p = uv * sizeK * uScale;

  float n1 = fbm(p * 0.50 + vec2(0.0, t * 0.032 * et));
  float n2 = fbm(p * 0.68 + vec2(3.7, 1.9) - t * 0.026 * et);
  float n3 = fbm(p * 0.92 + vec2(n1 * 0.9, n2 * 0.9) + vec2(1.3, 5.1) + t * 0.020 * et);

  float marble = fbm(p * 1.35 + vec2(n2 * 1.2, n1 * 1.2) + vec2(-t * 0.021 * et, t * 0.017 * et));

  float angEdge = atan(uv.y, uv.x) + n1 * 0.22 + t * 0.015;
  vec2 circ = vec2(cos(angEdge), sin(angEdge));
  float rayA = snoise(circ * 2.2 + vec2(0.0, t * 0.10 * et) + vec2(uBeat * 0.15, 0.0));
  float rayB = snoise(circ * 4.5 + vec2(4.0, 1.0) + vec2(t * 0.06 * et, -t * 0.09 * et));
  float rays = max(0.0, rayA * 0.62 + rayB * 0.38);
  rays *= rays;

  float r = (length(uv * vec2(1.0, 1.14)) + n3 * 0.13 + marble * 0.03) / breath;
  float edge = 0.55 * mix(0.82, 1.20, uSoftness)
    + rays * uRays * (0.35 + 0.65 * star) * (1.0 + uBeat * 0.55 + uScream * 0.3 + eCl * 0.35);
  float upness = clamp(uv.y / max(length(uv), 1e-4), 0.0, 1.0);
  float flick = 0.6 + 0.4 * snoise(vec2(t * 2.5, length(uv) * 7.0 - t * 3.5));
  edge += uFxFire * upness * upness * (0.06 + 0.16 * flick) * (0.6 + 0.6 * eCl);

  float mask = 1.0 - smoothstep(edge * 0.30, edge * 0.95, r);
  mask = pow(clamp(mask, 0.0, 1.0), 1.1);
  vec2 frag01 = fragCoord / uRes;
  vec2 db = min(frag01, 1.0 - frag01) * uRes / min(uRes.x, uRes.y);
  float border = smoothstep(0.0, 0.16, min(db.x, db.y));
  mask *= border;

  float f = n3;
  float f2 = marble;

  vec3 base = hue2rgb(fract(0.895 + uHue + f * 0.12));
  vec3 deep = hue2rgb(fract(0.955 + uHue + f * 0.10));
  vec3 accent = hue2rgb(fract(0.925 + uHue + f2 * 0.10));

  vec3 lumW = vec3(0.2126, 0.7152, 0.0722);
  base = mix(vec3(dot(base, lumW)), base, 0.82);
  deep = mix(vec3(dot(deep, lumW)), deep, 0.82);
  accent = mix(vec3(dot(accent, lumW)), accent, 0.82);

  vec3 col = mix(deep * 0.6, base, smoothstep(-0.55, 0.65, f));
  col = mix(col, accent, smoothstep(0.05, 0.55, f2) * 0.55);
  col = mix(col, vec3(1.03, 0.99, 0.94), smoothstep(0.55, 0.92, f2));
  col += base * (1.0 - smoothstep(0.0, 0.5, abs(f))) * 0.08;
  float g = exp(-dot(uv, uv) * 3.0);
  col += mix(vec3(1.0), base, 0.35) * g * (0.38 - 0.18 * bgL);

  float band = abs(fract(f * 2.5 + t * 0.05) - 0.5);
  float neonC = uNeon / (1.0 + (uBeat + uScream) * 0.9);
  float ribbon = (1.0 - smoothstep(0.0, 0.10, band)) * 0.6 * loopGate;
  float haloL = (1.0 - smoothstep(0.0, 0.28, band)) * 0.28 * loopGate;
  float inner = 1.0 - smoothstep(edge * 0.30, edge * 0.80, r);
  col += vec3(1.0) * (ribbon + haloL) * neonC * mask * inner;

  float beamSum = 0.0;
  float drive = clamp(uBeat + uScream, 0.0, 1.0);
  float reach = edge * (1.9 + (uBeat + uScream) * 0.85 + eCl * 0.6);
  float straight = 1.0 - drive * 0.55;
  for (int i = 0; i < 9; i++) {
    float fi = float(i);
    float drv = (mod(fi, 2.0) < 1.0) ? uBeat : uScream;
    float dir = (fi / 9.0) * 6.2831853
      + t * 0.03 * (mod(fi, 2.0) * 2.0 - 1.0)
      + snoise(vec2(fi * 7.31, t * 0.05 + fi)) * 0.35 * straight;
    float da = atan(uv.y, uv.x) - dir;
    da = atan(sin(da), cos(da));
    float w = (0.20 + 0.04 * sin(t * 0.18 + fi * 2.1)) * (1.0 - drive * 0.30);
    float shaft = exp(-da * da / (w * w));
    shaft *= 1.0 + drv * 1.1;
    float rad = length(uv);
    float innerR = smoothstep(edge * 0.25, edge * 0.95, rad);
    float outer = 1.0 - smoothstep(edge * 0.9, reach, rad);
    float fall = innerR * outer;
    beamSum += shaft * fall;
  }
  beamSum *= 0.28 + 0.30 * star + eCl * 0.45 + uBeat * 0.55;
  col += base * beamSum * (0.05 + 0.13 * bgL);
  col += vec3(1.0, 0.97, 0.92) * beamSum * beamSum * (0.09 - 0.05 * bgL);

  float ringA = 0.0;
  for (int j = 0; j < 2; j++) {
    float fj = float(j);
    float ph = fract(t * 0.45 + fj * 0.5);
    float rr = edge * (0.05 + ph * 0.85);
    float dr = (length(uv) - rr) * 9.0;
    ringA += exp(-dr * dr) * (1.0 - ph) * (0.2 + uBeat * 0.8 + uScream * 0.35);
  }
  col += mix(vec3(1.0), base, 0.7) * ringA * 0.12 * mask;

  if (uFxFire > 0.01) {
    float ember = 0.0;
    for (int i = 0; i < 10; i++) {
      float fi = float(i);
      float h1 = fract(sin(fi * 12.9898) * 43758.5453);
      float h2 = fract(sin(fi * 78.233 + 17.0) * 12543.1234);
      float prog = fract(t * (0.15 + h1 * 0.25) + h2);
      vec2 ep = vec2((h1 - 0.5) * edge * 1.2 + sin(t * 1.5 + fi * 1.9) * 0.05 * (0.3 + prog),
                     edge * 0.4 - prog * edge * 1.8);
      float d = length(uv - ep);
      float tw = 0.5 + 0.5 * sin(t * 5.0 + fi * 2.3);
      ember += smoothstep(0.035, 0.0, d) * (1.0 - prog) * tw;
    }
    col += mix(vec3(1.0, 0.55, 0.20), vec3(1.0, 0.85, 0.50), f2) * ember * 0.5 * uFxFire * (0.6 + uScream * 0.8);
  }

  col = col / (1.0 + max(col - 1.0, 0.0));

  col = mix(col, uBg, 0.04);

  float glowA = clamp(beamSum * 0.22, 0.0, 0.5);
  float a = clamp((mask + glowA) * uIntensity * 0.96, 0.0, 1.0);

  fragColor = vec4(col * a, a);
}
