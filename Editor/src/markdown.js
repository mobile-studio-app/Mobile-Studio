// Markdown to HTML for the preview (CommonMark's common parts and GitHub's tables, task lists
// and strikethrough). Raw HTML in the source is shown as text, never run.

const escapeHTML = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const escapeAttr = (s) => escapeHTML(s).replace(/'/g, '&#39;');

/** Inline markup: code, images, links, emphasis, strikethrough, autolinks and hard breaks. */
export function inline(text) {
  const codes = [];
  // Code spans first, so nothing inside them is touched.
  let s = text.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, (_, ticks, code) => {
    codes.push(`<code>${escapeHTML(code.trim() || code)}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = escapeHTML(s);
  s = s.replace(/!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\s*\)/g,
    (_, alt, src, title) => `<img alt="${escapeAttr(alt)}" data-src="${escapeAttr(src)}"${title ? ` title="${escapeAttr(title)}"` : ''}>`);
  s = s.replace(/\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\s*\)/g,
    (_, label, href, title) => `<a href="${escapeAttr(href)}"${title ? ` title="${escapeAttr(title)}"` : ''}>${label}</a>`);
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2">$2</a>');
  s = s.replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, '<strong>$2</strong>');
  s = s.replace(/(^|[^\w*])\*(?=\S)([^*]*?\S)\*(?!\*)/g, '$1<em>$2</em>');
  s = s.replace(/(^|[^\w_])_(?=\S)([^_]*?\S)_(?![\w_])/g, '$1<em>$2</em>');
  s = s.replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>');
  s = s.replace(/ {2,}\n|\\\n/g, '<br>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[+i]);
}

const isBlank = (line) => !line.trim();

/** Block structure: headings, code, quotes, lists, tables, rules and paragraphs. */
export function renderMarkdown(source) {
  const lines = source.replace(/\r\n?/g, '\n').replace(/\t/g, '    ').split('\n');
  return blocks(lines);
}

function blocks(lines) {
  let html = '';
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) { i++; continue; }

    let m = /^ {0,3}(`{3,}|~{3,})\s*([\w+#.-]*)/.exec(line);
    if (m) {
      const fence = m[1];
      const code = [];
      i++;
      while (i < lines.length && !lines[i].trimStart().startsWith(fence)) code.push(lines[i++]);
      i++;
      html += `<pre><code${m[2] ? ` class="language-${escapeAttr(m[2])}"` : ''}>${escapeHTML(code.join('\n'))}</code></pre>`;
      continue;
    }
    m = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (m) {
      const text = m[2];
      const id = text.toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s+/g, '-');
      html += `<h${m[1].length} id="${escapeAttr(id)}">${inline(text)}</h${m[1].length}>`;
      i++;
      continue;
    }
    if (/^ {0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) { html += '<hr>'; i++; continue; }
    if (/^ {0,3}>/.test(line)) {
      const quote = [];
      while (i < lines.length && !isBlank(lines[i]) && (/^ {0,3}>/.test(lines[i]) || quote.length)) {
        quote.push(lines[i].replace(/^ {0,3}> ?/, ''));
        i++;
      }
      html += `<blockquote>${blocks(quote)}</blockquote>`;
      continue;
    }
    if (/^\s*\|?.+\|.+/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const align = cells(lines[i + 1]).map((c) => (c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : ''));
      const head = cells(line);
      let table = '<table><thead><tr>' + head.map((c, k) => `<th${align[k] ? ` style="text-align:${align[k]}"` : ''}>${inline(c)}</th>`).join('') + '</tr></thead><tbody>';
      i += 2;
      while (i < lines.length && !isBlank(lines[i]) && lines[i].includes('|')) {
        table += '<tr>' + cells(lines[i]).map((c, k) => `<td${align[k] ? ` style="text-align:${align[k]}"` : ''}>${inline(c)}</td>`).join('') + '</tr>';
        i++;
      }
      html += table + '</tbody></table>';
      continue;
    }
    m = /^( {0,3})([-*+]|\d{1,9}[.)])\s+/.exec(line);
    if (m) {
      const ordered = /\d/.test(m[2]);
      const start = ordered ? parseInt(m[2], 10) : 1;
      const items = [];
      const markerRe = /^( {0,3})([-*+]|\d{1,9}[.)])\s+(.*)$/;
      while (i < lines.length) {
        const item = markerRe.exec(lines[i]);
        if (!item || /\d/.test(item[2]) !== ordered) break;
        const body = [item[3]];
        const indent = item[1].length + item[2].length + 1;
        i++;
        while (i < lines.length && (isBlank(lines[i]) ? (i + 1 < lines.length && /^\s{2,}/.test(lines[i + 1])) : (/^\s{2,}/.test(lines[i]) && !markerRe.test(lines[i])) || /^\s{2,}([-*+]|\d+[.)])\s/.test(lines[i]))) {
          body.push(lines[i].replace(new RegExp(`^ {0,${Math.max(indent, 2)}}`), ''));
          i++;
        }
        items.push(body);
        while (i < lines.length && isBlank(lines[i]) && i + 1 < lines.length && markerRe.test(lines[i + 1])) i++;
      }
      const tag = ordered ? 'ol' : 'ul';
      html += `<${tag}${ordered && start !== 1 ? ` start="${start}"` : ''}>` + items.map((body) => {
        const task = /^\[([ xX])\]\s+/.exec(body[0]);
        if (task) body[0] = body[0].slice(task[0].length);
        const inner = body.length === 1 ? inline(body[0]) : blocks(body);
        return task ? `<li class="task"><input type="checkbox" disabled${task[1] !== ' ' ? ' checked' : ''}> ${inner}</li>` : `<li>${inner}</li>`;
      }).join('') + `</${tag}>`;
      continue;
    }
    // A paragraph runs until a blank line or another block starts.
    const para = [];
    while (i < lines.length && !isBlank(lines[i]) && !/^ {0,3}(#{1,6}\s|`{3,}|~{3,}|>|([-*_])(\s*\2){2,}\s*$)/.test(lines[i])
      && !(para.length && /^ {0,3}([-*+]|\d{1,9}[.)])\s+/.test(lines[i]))
      && !(para.length && /^ {0,3}(=+|-+)\s*$/.test(lines[i]))) {
      para.push(lines[i]);
      i++;
    }
    // Setext headings: a paragraph underlined with === or ---.
    if (i < lines.length && para.length && /^ {0,3}(=+|-+)\s*$/.test(lines[i])) {
      const level = lines[i].trim()[0] === '=' ? 1 : 2;
      html += `<h${level}>${inline(para.join('\n'))}</h${level}>`;
      i++;
      continue;
    }
    if (!para.length) { html += `<p>${inline(lines[i])}</p>`; i++; continue; }
    html += `<p>${inline(para.join('\n'))}</p>`;
  }
  return html;
}
