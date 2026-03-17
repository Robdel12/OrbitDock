import { marked } from 'marked'

marked.setOptions({
  gfm: true,
  breaks: true,
})

const renderMarkdown = (text) => {
  if (!text) return ''
  return marked.parse(text)
}

export { renderMarkdown }
