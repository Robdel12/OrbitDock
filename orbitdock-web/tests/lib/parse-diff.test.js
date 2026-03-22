import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { extractDiffText, parseDiff } from '../../src/lib/parse-diff.js'

describe('parseDiff', () => {
  it('parses a simple unified diff with additions and deletions', () => {
    const diff = `--- a/file.js
+++ b/file.js
@@ -1,3 +1,3 @@
 const a = 1
-const b = 2
+const b = 3
 const c = 4`

    const lines = parseDiff(diff)
    assert.strictEqual(lines.length, 4)
    assert.deepStrictEqual(lines[0], { kind: 'context', old_line: 1, new_line: 1, content: 'const a = 1' })
    assert.deepStrictEqual(lines[1], { kind: 'deletion', old_line: 2, new_line: null, content: 'const b = 2' })
    assert.deepStrictEqual(lines[2], { kind: 'addition', old_line: null, new_line: 2, content: 'const b = 3' })
    assert.deepStrictEqual(lines[3], { kind: 'context', old_line: 3, new_line: 3, content: 'const c = 4' })
  })

  it('tracks line numbers across hunks correctly', () => {
    const diff = `@@ -10,2 +10,3 @@
 unchanged
+added line
 also unchanged`

    const lines = parseDiff(diff)
    assert.strictEqual(lines[0].old_line, 10)
    assert.strictEqual(lines[0].new_line, 10)
    assert.strictEqual(lines[1].kind, 'addition')
    assert.strictEqual(lines[1].new_line, 11)
    assert.strictEqual(lines[2].old_line, 11)
    assert.strictEqual(lines[2].new_line, 12)
  })

  it('handles pure addition diff', () => {
    const diff = `@@ -0,0 +1,2 @@
+line one
+line two`

    const lines = parseDiff(diff)
    assert.strictEqual(lines.length, 2)
    assert.strictEqual(lines[0].kind, 'addition')
    assert.strictEqual(lines[0].new_line, 1)
    assert.strictEqual(lines[1].new_line, 2)
  })

  it('handles pure deletion diff', () => {
    const diff = `@@ -1,2 +1,0 @@
-removed one
-removed two`

    const lines = parseDiff(diff)
    assert.strictEqual(lines.length, 2)
    assert.strictEqual(lines[0].kind, 'deletion')
    assert.strictEqual(lines[0].old_line, 1)
    assert.strictEqual(lines[1].old_line, 2)
  })

  it('strips trailing blank context lines', () => {
    const diff = `@@ -1,3 +1,3 @@
 first
 second
 `

    const lines = parseDiff(diff)
    assert.strictEqual(lines.length, 2)
    assert.strictEqual(lines[1].content, 'second')
  })

  it('returns empty array for null, undefined, or non-string input', () => {
    assert.deepStrictEqual(parseDiff(null), [])
    assert.deepStrictEqual(parseDiff(undefined), [])
    assert.deepStrictEqual(parseDiff(''), [])
    assert.deepStrictEqual(parseDiff(42), [])
  })

  it('skips diff --git and index header lines in multi-file input', () => {
    const diff = `diff --git a/file.js b/file.js
index abc123..def456 100644
--- a/file.js
+++ b/file.js
@@ -1,3 +1,3 @@
 const a = 1
-const b = 2
+const b = 3
 const c = 4`

    const lines = parseDiff(diff)
    // Should only have content lines, no diff --git or index lines
    assert.strictEqual(lines.length, 4)
    assert.deepStrictEqual(lines[0], { kind: 'context', old_line: 1, new_line: 1, content: 'const a = 1' })
    assert.deepStrictEqual(lines[1], { kind: 'deletion', old_line: 2, new_line: null, content: 'const b = 2' })
    assert.deepStrictEqual(lines[2], { kind: 'addition', old_line: null, new_line: 2, content: 'const b = 3' })
    assert.deepStrictEqual(lines[3], { kind: 'context', old_line: 3, new_line: 3, content: 'const c = 4' })
  })

  it('handles concatenated multi-turn same-file diffs', () => {
    // Two turns editing the same file — concatenated with newline
    const diff = `diff --git a/app.js b/app.js
--- a/app.js
+++ b/app.js
@@ -1,3 +1,3 @@
 const a = 1
-const b = 2
+const b = 42
 const c = 3
diff --git a/app.js b/app.js
--- a/app.js
+++ b/app.js
@@ -10,2 +10,3 @@
 const x = 10
+const y = 11
 const z = 12`

    const lines = parseDiff(diff)
    // Should produce content lines from BOTH turns (7 total)
    assert.strictEqual(lines.length, 7)

    // Turn 1 lines — starting at line 1
    assert.strictEqual(lines[0].old_line, 1)
    assert.strictEqual(lines[1].kind, 'deletion')
    assert.strictEqual(lines[1].old_line, 2)
    assert.strictEqual(lines[2].kind, 'addition')
    assert.strictEqual(lines[2].new_line, 2)

    // Turn 2 lines — starting at line 10
    assert.strictEqual(lines[4].old_line, 10)
    assert.strictEqual(lines[5].kind, 'addition')
    assert.strictEqual(lines[5].new_line, 11)
    assert.strictEqual(lines[6].old_line, 11)
  })

  it('skips rename and file mode metadata lines', () => {
    const diff = `diff --git a/old.js b/new.js
similarity index 95%
rename from old.js
rename to new.js
--- a/old.js
+++ b/new.js
@@ -1,2 +1,2 @@
-const old = true
+const renamed = true
 const keep = true`

    const lines = parseDiff(diff)
    assert.strictEqual(lines.length, 3)
    assert.strictEqual(lines[0].kind, 'deletion')
    assert.strictEqual(lines[1].kind, 'addition')
    assert.strictEqual(lines[2].kind, 'context')
  })
})

describe('extractDiffText', () => {
  it('prefers request.diff over other fields', () => {
    assert.strictEqual(extractDiffText({ diff: 'diff-text', content: 'content-text' }), 'diff-text')
  })

  it('falls back to request.content', () => {
    assert.strictEqual(extractDiffText({ content: 'content-text' }), 'content-text')
  })

  it('falls back to request.preview.value', () => {
    assert.strictEqual(extractDiffText({ preview: { value: 'preview-text' } }), 'preview-text')
  })

  it('returns null when no diff text is available', () => {
    assert.strictEqual(extractDiffText({}), null)
    assert.strictEqual(extractDiffText({ diff: 42 }), null)
  })
})
