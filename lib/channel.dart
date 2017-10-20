/**
 *
 * @param {string} topic
 * @param {Object} params
 * @param {Socket} socket
 */
class Channel {
  Channel(topic, params, socket) {
    this.state       = CHANNEL_STATES.closed
    this.topic       = topic
    this.params      = params || {}
    this.socket      = socket
    this.bindings    = []
    this.timeout     = this.socket.timeout
    this.joinedOnce  = false
    this.joinPush    = new Push(this, CHANNEL_EVENTS.join, this.params, this.timeout)
    this.pushBuffer  = []
    this.rejoinTimer  = new Timer(
      () => this.rejoinUntilConnected(),
      this.socket.reconnectAfterMs
    )
    this.joinPush.receive("ok", () => {
      this.state = CHANNEL_STATES.joined
      this.rejoinTimer.reset()
      this.pushBuffer.forEach( pushEvent => pushEvent.send() )
      this.pushBuffer = []
    })
    this.onClose( () => {
      this.rejoinTimer.reset()
      this.socket.log("channel", `close ${this.topic} ${this.joinRef()}`)
      this.state = CHANNEL_STATES.closed
      this.socket.remove(this)
    })
    this.onError( reason => { if(this.isLeaving() || this.isClosed()){ return }
      this.socket.log("channel", `error ${this.topic}`, reason)
      this.state = CHANNEL_STATES.errored
      this.rejoinTimer.scheduleTimeout()
    })
    this.joinPush.receive("timeout", () => { if(!this.isJoining()){ return }
      this.socket.log("channel", `timeout ${this.topic} (${this.joinRef()})`, this.joinPush.timeout)
      let leavePush = new Push(this, CHANNEL_EVENTS.leave, {}, this.timeout)
      leavePush.send()
      this.state = CHANNEL_STATES.errored
      this.joinPush.reset()
      this.rejoinTimer.scheduleTimeout()
    })
    this.on(CHANNEL_EVENTS.reply, (payload, ref) => {
      this.trigger(this.replyEventName(ref), payload)
    })
  }

  rejoinUntilConnected(){
    this.rejoinTimer.scheduleTimeout()
    if(this.socket.isConnected()){
      this.rejoin()
    }
  }

  join(timeout = this.timeout){
    if(this.joinedOnce){
      throw(`tried to join multiple times. 'join' can only be called a single time per channel instance`)
    } else {
      this.joinedOnce = true
      this.rejoin(timeout)
      return this.joinPush
    }
  }

  onClose(callback){ this.on(CHANNEL_EVENTS.close, callback) }

  onError(callback){
    this.on(CHANNEL_EVENTS.error, reason => callback(reason) )
  }

  on(event, callback){ this.bindings.push({event, callback}) }

  off(event){ this.bindings = this.bindings.filter( bind => bind.event !== event ) }

  canPush(){ return this.socket.isConnected() && this.isJoined() }

  push(event, payload, timeout = this.timeout){
    if(!this.joinedOnce){
      throw(`tried to push '${event}' to '${this.topic}' before joining. Use channel.join() before pushing events`)
    }
    let pushEvent = new Push(this, event, payload, timeout)
    if(this.canPush()){
      pushEvent.send()
    } else {
      pushEvent.startTimeout()
      this.pushBuffer.push(pushEvent)
    }

    return pushEvent
  }

  /** Leaves the channel
   *
   * Unsubscribes from server events, and
   * instructs channel to terminate on server
   *
   * Triggers onClose() hooks
   *
   * To receive leave acknowledgements, use the a `receive`
   * hook to bind to the server ack, ie:
   *
   * ```javascript
   *     channel.leave().receive("ok", () => alert("left!") )
   * ```
   */
  leave(timeout = this.timeout){
    this.state = CHANNEL_STATES.leaving
    let onClose = () => {
      this.socket.log("channel", `leave ${this.topic}`)
      this.trigger(CHANNEL_EVENTS.close, "leave")
    }
    let leavePush = new Push(this, CHANNEL_EVENTS.leave, {}, timeout)
    leavePush.receive("ok", () => onClose() )
             .receive("timeout", () => onClose() )
    leavePush.send()
    if(!this.canPush()){ leavePush.trigger("ok", {}) }

    return leavePush
  }

  /**
   * Overridable message hook
   *
   * Receives all events for specialized message handling
   * before dispatching to the channel callbacks.
   *
   * Must return the payload, modified or unmodified
   */
  onMessage(event, payload, ref){ return payload }


  // private

  isMember(topic, event, payload, joinRef){
    if(this.topic !== topic){ return false }
    let isLifecycleEvent = CHANNEL_LIFECYCLE_EVENTS.indexOf(event) >= 0

    if(joinRef && isLifecycleEvent && joinRef !== this.joinRef()){
      this.socket.log("channel", "dropping outdated message", {topic, event, payload, joinRef})
      return false
    } else {
      return true
    }
  }

  joinRef(){ return this.joinPush.ref }

  sendJoin(timeout){
    this.state = CHANNEL_STATES.joining
    this.joinPush.resend(timeout)
  }

  rejoin(timeout = this.timeout){ if(this.isLeaving()){ return }
    this.sendJoin(timeout)
  }

  trigger(event, payload, ref, joinRef){
    let handledPayload = this.onMessage(event, payload, ref, joinRef)
    if(payload && !handledPayload){ throw("channel onMessage callbacks must return the payload, modified or unmodified") }

    this.bindings.filter( bind => bind.event === event)
                 .map( bind => bind.callback(handledPayload, ref, joinRef || this.joinRef()))
  }

  String replyEventName(ref){ return "chan_reply_${ref}"; }

  bool isClosed() { return this.state == CHANNEL_STATES.closed; }
  bool isErrored(){ return this.state == CHANNEL_STATES.errored; }
  bool isJoined() { return this.state == CHANNEL_STATES.joined; }
  bool isJoining(){ return this.state == CHANNEL_STATES.joining; }
  bool isLeaving(){ return this.state == CHANNEL_STATES.leaving; }
}