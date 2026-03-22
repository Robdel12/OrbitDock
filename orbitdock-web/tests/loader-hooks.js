import { transformSync } from 'esbuild'

/**
 * Node module-loader hooks:
 * - Transpiles .jsx files with Preact's automatic JSX runtime via esbuild.
 * - Stubs .css/.module.css imports with an empty object (CSS modules return
 *   a Proxy that yields the class name as-is, matching Vite's test behavior).
 */

const CSS_RE = /\.css$/

const classNameProxy = `export default new Proxy({}, { get: (_, name) => name });\n`

export async function load(url, context, nextLoad) {
  if (CSS_RE.test(url)) {
    return { format: 'module', source: classNameProxy, shortCircuit: true }
  }

  if (url.endsWith('.jsx')) {
    let { source } = await nextLoad(url, { ...context, format: 'module' })
    if (typeof source !== 'string') source = source.toString()
    const { code } = transformSync(source, {
      loader: 'jsx',
      jsx: 'automatic',
      jsxImportSource: 'preact',
      format: 'esm',
      sourcefile: new URL(url).pathname,
    })
    return { format: 'module', source: code, shortCircuit: true }
  }

  return nextLoad(url, context)
}
