import { render } from 'preact'
import { App } from './app.jsx'
import { connect } from './stores/connection.js'
import './styles/global.css'

const wsUrl = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`
connect(wsUrl)

render(<App />, document.getElementById('app'))
