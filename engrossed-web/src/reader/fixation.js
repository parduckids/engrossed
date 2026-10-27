// Bolds the first few letters of each word.
//
// A port of TextStyling.fixationBolded from the app. The idea is that a bolded
// head gives the eye a fixation point so it stops drifting mid-line. It is off
// by default and offered as a setting rather than a claim: the evidence for it
// is thin, and some people find it actively worse.

function boldPrefixLength(length) {
  if (length === 0) return 0;
  if (length <= 3) return 1;
  if (length <= 6) return 2;
  if (length <= 9) return 3;
  return Math.max(3, Math.floor(length * 0.4));
}

const LETTER = /[\p{L}\p{M}]/u;
const WORD_CHAR = /[\p{L}\p{M}'’]/u;

/**
 * Returns a DocumentFragment so the caller never has to build HTML from a
 * string, which keeps page text out of innerHTML entirely.
 */
export function fixationBolded(text, doc = document) {
  const fragment = doc.createDocumentFragment();
  const characters = [...text];
  let i = 0;

  while (i < characters.length) {
    // Copy any run of non-letters verbatim.
    if (!LETTER.test(characters[i])) {
      let run = "";
      while (i < characters.length && !LETTER.test(characters[i])) {
        run += characters[i];
        i += 1;
      }
      fragment.appendChild(doc.createTextNode(run));
      continue;
    }

    let word = "";
    while (i < characters.length && WORD_CHAR.test(characters[i])) {
      word += characters[i];
      i += 1;
    }

    const boldCount = boldPrefixLength([...word].length);
    const head = doc.createElement("b");
    head.textContent = [...word].slice(0, boldCount).join("");
    fragment.appendChild(head);

    const tail = [...word].slice(boldCount).join("");
    if (tail) fragment.appendChild(doc.createTextNode(tail));
  }

  return fragment;
}
