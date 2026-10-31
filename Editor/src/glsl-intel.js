// GLSL checks shared by .glsl files and shader code inside Lua strings.

const UNIFORM_INIT = /^[ \t]*(?:uniform|extern)\b[^;=\n]*?(=[^;\n]+);/gm;

/**
 * Flags `uniform float k = 1.0;`: desktop GLSL allows it, GLSL ES (iOS, Android) doesn't.
 * DuoCode's runtime moves these values to shader:send so the game still runs here.
 */
export function uniformInitialiserDiagnostics(text) {
  const out = [];
  for (const m of text.matchAll(UNIFORM_INIT)) {
    const from = m.index + m[0].indexOf(m[1]);
    out.push({
      from,
      to: from + m[1].length,
      severity: 'info',
      source: 'GLSL',
      message: 'Uniform initial values aren’t allowed on iOS/Android (GLSL ES). Mobile Studio sends this value for you ' +
        'when running here; for other mobile builds, remove it and use shader:send instead.',
    });
  }
  return out;
}
