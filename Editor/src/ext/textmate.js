// TextMate grammars from extensions, tokenised by VS Code's own engine (vscode-textmate with the
// Oniguruma regex library compiled to WebAssembly) and coloured through CodeMirror's highlight
// tags, so they follow whichever theme is active.
import { StreamLanguage } from '@codemirror/language';
import * as vsctm from 'vscode-textmate';
import * as oniguruma from 'vscode-oniguruma';
import onigWasm from '../../node_modules/vscode-oniguruma/release/onig.wasm';
import { contributions, readExtensionFile, parseJSONC } from './registry.js';

let onigReady = null;
function onigLib() {
  if (!onigReady) {
    onigReady = oniguruma.loadWASM(onigWasm.buffer.slice(onigWasm.byteOffset, onigWasm.byteOffset + onigWasm.byteLength)).then(() => ({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (s) => new oniguruma.OnigString(s),
    }));
  }
  return onigReady;
}

let registry = null;
function getRegistry() {
  if (!registry) {
    registry = new vsctm.Registry({
      onigLib: onigLib(),
      loadGrammar: async (scopeName) => {
        const g = contributions.grammars.get(scopeName);
        if (!g) return null;
        try {
          const text = await readExtensionFile(g.extId, g.path);
          return vsctm.parseRawGrammar(text, g.path);
        } catch (e) {
          return null;
        }
      },
      getInjections: (scopeName) => {
        const out = [];
        for (const [scope, g] of contributions.grammars) {
          if (g.injectTo && g.injectTo.includes(scopeName)) out.push(scope);
        }
        return out;
      },
    });
  }
  return registry;
}

/** Forget loaded grammars (extensions changed). */
export function resetGrammars() {
  registry = null;
  languages.clear();
}

// TextMate scope -> CodeMirror highlight tag (as a StreamLanguage style). First match wins, so
// more specific scopes come first.
const SCOPE_STYLES = [
  ['comment', 'comment'],
  ['punctuation.definition.comment', 'comment'],
  ['string.regexp', 'regexp'],
  ['constant.character.escape', 'escape'],
  ['string', 'string'],
  ['constant.numeric', 'number'],
  ['constant.language.boolean', 'bool'],
  ['constant.language', 'atom'],
  ['constant.character', 'character'],
  ['constant', 'variableName.constant'],
  ['keyword.control', 'controlKeyword'],
  ['keyword.operator', 'operator'],
  ['keyword', 'keyword'],
  ['storage.type', 'keyword'],
  ['storage.modifier', 'modifier'],
  ['storage', 'keyword'],
  // Plain "function": with a second modifier the theme's variable rule ties and wins.
  ['entity.name.function', 'variableName.function'],
  ['support.function', 'variableName.function'],
  ['meta.function-call', 'variableName.function'],
  ['entity.name.type', 'typeName'],
  ['entity.name.class', 'className'],
  ['entity.other.inherited-class', 'className'],
  ['support.type', 'typeName.standard'],
  ['support.class', 'className.standard'],
  ['entity.name.namespace', 'namespace'],
  ['entity.name.tag', 'tagName'],
  ['entity.other.attribute-name', 'attributeName'],
  ['entity.name', 'variableName.definition'],
  ['variable.parameter', 'variableName.local'],
  ['variable.other.property', 'propertyName'],
  ['variable.other.member', 'propertyName'],
  ['support.variable.property', 'propertyName'],
  ['variable.other.constant', 'variableName.constant'],
  ['variable.language', 'self'],
  ['support.variable', 'variableName.standard'],
  ['variable', 'variableName'],
  ['support.constant', 'atom'],
  ['markup.heading', 'heading'],
  ['markup.bold', 'strong'],
  ['markup.italic', 'emphasis'],
  ['markup.underline.link', 'link'],
  ['markup.inline.raw', 'monospace'],
  ['markup.quote', 'quote'],
  ['markup.list', 'list'],
  ['markup.inserted', 'inserted'],
  ['markup.deleted', 'deleted'],
  ['invalid', 'invalid'],
  ['meta.preprocessor', 'meta'],
  ['punctuation.definition.tag', 'angleBracket'],
  ['punctuation.separator', 'separator'],
  ['punctuation', 'punctuation'],
];

const styleCache = new Map();

/** The highlight style for a token's scope stack (innermost scope decides). */
export function styleForScopes(scopes) {
  for (let i = scopes.length - 1; i >= 1; i--) {
    const scope = scopes[i];
    let style = styleCache.get(scope);
    if (style === undefined) {
      style = null;
      for (const [prefix, s] of SCOPE_STYLES) {
        if (scope === prefix || scope.startsWith(prefix + '.')) { style = s; break; }
      }
      styleCache.set(scope, style);
    }
    if (style) return style;
  }
  return null;
}

const languages = new Map();   // language id -> Promise<{ language, data }>

/** A CodeMirror language for an extension language id, or null if it has no grammar. */
export function loadTextMateLanguage(lang) {
  const scopeName = contributions.grammarForLanguage.get(lang.id);
  if (!scopeName) return Promise.resolve(null);
  if (!languages.has(lang.id)) {
    languages.set(lang.id, (async () => {
      const grammar = await getRegistry().loadGrammar(scopeName);
      if (!grammar) return null;
      const data = await languageConfiguration(lang);
      return streamLanguage(grammar, lang.id, data);
    })().catch(() => null));
  }
  return languages.get(lang.id);
}

/** language-configuration.json: comments and auto-closing brackets. */
async function languageConfiguration(lang) {
  if (!lang.configuration) return {};
  try {
    const config = parseJSONC(await readExtensionFile(lang.configuration.extId, lang.configuration.path));
    const data = {};
    if (config.comments) {
      data.commentTokens = {};
      if (config.comments.lineComment) data.commentTokens.line = config.comments.lineComment;
      if (Array.isArray(config.comments.blockComment)) {
        data.commentTokens.block = { open: config.comments.blockComment[0], close: config.comments.blockComment[1] };
      }
    }
    const pairs = (config.autoClosingPairs || []).map((p) => (Array.isArray(p) ? p[0] : p.open)).filter((s) => typeof s === 'string' && s.length === 1);
    if (pairs.length) data.closeBrackets = { brackets: pairs };
    return data;
  } catch (e) {
    return {};
  }
}

function streamLanguage(grammar, name, languageData) {
  return StreamLanguage.define({
    name,
    startState: () => ({ stack: vsctm.INITIAL, next: null, tokens: null, index: 0 }),
    copyState: (s) => ({ stack: s.stack, next: s.next, tokens: s.tokens, index: s.index }),
    token(stream, state) {
      if (stream.sol() || !state.tokens) {
        if (state.next) state.stack = state.next;
        const line = stream.string;
        // Very long lines (minified files) would stall the editor; leave them plain.
        if (line.length > 3000) {
          state.tokens = [];
          state.next = state.stack;
          stream.skipToEnd();
          return null;
        }
        const result = grammar.tokenizeLine(line, state.stack, 200);
        state.tokens = result.tokens;
        state.next = result.ruleStack;
        state.index = 0;
      }
      const tokens = state.tokens;
      while (state.index < tokens.length && tokens[state.index].endIndex <= stream.pos) state.index++;
      const token = tokens[state.index];
      if (!token) {
        stream.skipToEnd();
        return null;
      }
      stream.pos = Math.min(Math.max(token.endIndex, stream.pos + 1), stream.string.length);
      return styleForScopes(token.scopes);
    },
    blankLine(state) {
      if (state.next) state.stack = state.next;
      state.next = grammar.tokenizeLine('', state.stack).ruleStack;
      state.tokens = null;
    },
    languageData,
  });
}
