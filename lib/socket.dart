class Socket {

  constructor(endPoint, opts = {}){
    this.stateChangeCallbacks = {open: [], close: [], error: [], message: []}
    this.channels             = []
    this.sendBuffer           = []
    this.ref                  = 0
    this.timeout              = opts.timeout || DEFAULT_TIMEOUT
    this.transport            = opts.transport || window.WebSocket || LongPoll
    this.defaultEncoder       = Serializer.encode
    this.defaultDecoder       = Serializer.decode
    if(this.transport !== LongPoll){
      this.encode = opts.encode || this.defaultEncoder
      this.decode = opts.decode || this.defaultDecoder
    } else {
      this.encode = this.defaultEncoder
      this.decode = this.defaultDecoder
    }
    this.heartbeatIntervalMs  = opts.heartbeatIntervalMs || 30000
    this.reconnectAfterMs     = opts.reconnectAfterMs || function(tries){
      return [1000, 2000, 5000, 10000][tries - 1] || 10000
    }
    this.logger               = opts.logger || function(){} // noop
    this.longpollerTimeout    = opts.longpollerTimeout || 20000
    this.params               = opts.params || {}
    this.endPoint             = `${endPoint}/${TRANSPORTS.websocket}`
    this.heartbeatTimer       = null
    this.pendingHeartbeatRef  = null
    this.reconnectTimer       = new Timer(() => {
      this.disconnect(() => this.connect())
    }, this.reconnectAfterMs)
  }

  protocol(){ return location.protocol.match(/^https/) ? "wss" : "ws" }

  endPointURL(){
    let uri = Ajax.appendParams(
      Ajax.appendParams(this.endPoint, this.params), {vsn: VSN})
    if(uri.charAt(0) !== "/"){ return uri }
    if(uri.charAt(1) === "/"){ return `${this.protocol()}:${uri}` }

    return `${this.protocol()}://${location.host}${uri}`
  }

  disconnect(callback, code, reason){
    if(this.conn){
      this.conn.onclose = function(){} // noop
      if(code){ this.conn.close(code, reason || "") } else { this.conn.close() }
      this.conn = null
    }
    callback && callback()
  }

  /**
   *
   * @param {Object} params - The params to send when connecting, for example `{user_id: userToken}`
   */
  connect(params){
    if(params){
      console && console.log("passing params to connect is deprecated. Instead pass :params to the Socket constructor")
      this.params = params
    }
    if(this.conn){ return }

    this.conn = new this.transport(this.endPointURL())
    this.conn.timeout   = this.longpollerTimeout
    this.conn.onopen    = () => this.onConnOpen()
    this.conn.onerror   = error => this.onConnError(error)
    this.conn.onmessage = event => this.onConnMessage(event)
    this.conn.onclose   = event => this.onConnClose(event)
  }

  /**
   * Logs the message. Override `this.logger` for specialized logging. noops by default
   * @param {string} kind
   * @param {string} msg
   * @param {Object} data
   */
  log(kind, msg, data){ this.logger(kind, msg, data) }

  // Registers callbacks for connection state change events
  //
  // Examples
  //
  //    socket.onError(function(error){ alert("An error occurred") })
  //
  onOpen     (callback){ this.stateChangeCallbacks.open.push(callback) }
  onClose    (callback){ this.stateChangeCallbacks.close.push(callback) }
  onError    (callback){ this.stateChangeCallbacks.error.push(callback) }
  onMessage  (callback){ this.stateChangeCallbacks.message.push(callback) }

  onConnOpen(){
    this.log("transport", `connected to ${this.endPointURL()}`)
    this.flushSendBuffer()
    this.reconnectTimer.reset()
    if(!this.conn.skipHeartbeat){
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = setInterval(() => this.sendHeartbeat(), this.heartbeatIntervalMs)
    }
    this.stateChangeCallbacks.open.forEach( callback => callback() )
  }

  onConnClose(event){
    this.log("transport", "close", event)
    this.triggerChanError()
    clearInterval(this.heartbeatTimer)
    this.reconnectTimer.scheduleTimeout()
    this.stateChangeCallbacks.close.forEach( callback => callback(event) )
  }

  onConnError(error){
    this.log("transport", error)
    this.triggerChanError()
    this.stateChangeCallbacks.error.forEach( callback => callback(error) )
  }

  triggerChanError(){
    this.channels.forEach( channel => channel.trigger(CHANNEL_EVENTS.error) )
  }

  connectionState(){
    switch(this.conn && this.conn.readyState){
      case SOCKET_STATES.connecting: return "connecting"
      case SOCKET_STATES.open:       return "open"
      case SOCKET_STATES.closing:    return "closing"
      default:                       return "closed"
    }
  }

  isConnected(){ return this.connectionState() === "open" }

  remove(channel){
    this.channels = this.channels.filter(c => c.joinRef() !== channel.joinRef())
  }

  /**
   * Initiates a new channel for the given topic
   *
   * @param {string} topic
   * @param {Object} chanParams - Paramaters for the channel
   * @returns {Channel}
   */
  channel(topic, chanParams = {}){
    let chan = new Channel(topic, chanParams, this)
    this.channels.push(chan)
    return chan
  }

  push(data){
    let {topic, event, payload, ref, join_ref} = data
    let callback = () => {
      this.encode(data, result => {
        this.conn.send(result)
      })
    }
    this.log("push", `${topic} ${event} (${join_ref}, ${ref})`, payload)
    if(this.isConnected()){
      callback()
    }
    else {
      this.sendBuffer.push(callback)
    }
  }

  /**
   * Return the next message ref, accounting for overflows
   */
  makeRef(){
    let newRef = this.ref + 1
    if(newRef === this.ref){ this.ref = 0 } else { this.ref = newRef }

    return this.ref.toString()
  }

  sendHeartbeat(){ if(!this.isConnected()){ return }
    if(this.pendingHeartbeatRef){
      this.pendingHeartbeatRef = null
      this.log("transport", "heartbeat timeout. Attempting to re-establish connection")
      this.conn.close(WS_CLOSE_NORMAL, "hearbeat timeout")
      return
    }
    this.pendingHeartbeatRef = this.makeRef()
    this.push({topic: "phoenix", event: "heartbeat", payload: {}, ref: this.pendingHeartbeatRef})
  }

  flushSendBuffer(){
    if(this.isConnected() && this.sendBuffer.length > 0){
      this.sendBuffer.forEach( callback => callback() )
      this.sendBuffer = []
    }
  }

  onConnMessage(rawMessage){
    this.decode(rawMessage.data, msg => {
      let {topic, event, payload, ref, join_ref} = msg
      if(ref && ref === this.pendingHeartbeatRef){ this.pendingHeartbeatRef = null }

      this.log("receive", `${payload.status || ""} ${topic} ${event} ${ref && "(" + ref + ")" || ""}`, payload)
      this.channels.filter( channel => channel.isMember(topic, event, payload, join_ref) )
                   .forEach( channel => channel.trigger(event, payload, ref, join_ref) )
      this.stateChangeCallbacks.message.forEach( callback => callback(msg) )
    })
  }
}
