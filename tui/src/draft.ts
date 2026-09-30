export interface DraftSnapshot {
  text: string
  /** UTF-16 offset into text, independent of terminal cell widths. */
  cursor: number
}

function splice(snapshot: DraftSnapshot, start: number, end: number, text: string): DraftSnapshot {
  const cursor = snapshot.cursor <= start ? snapshot.cursor
    : snapshot.cursor >= end ? snapshot.cursor + text.length - (end - start)
    : start + text.length
  return { text: snapshot.text.slice(0, start) + text + snapshot.text.slice(end), cursor }
}

/** Pending paste resolution changes an edit's content, not the number of edits. */
export class DraftHistory {
  private states: DraftSnapshot[] = [{ text: "", cursor: 0 }]
  private index = 0

  record(snapshot: DraftSnapshot): void {
    if (this.states[this.index]!.text === snapshot.text) {
      this.states[this.index] = snapshot
      return
    }
    this.states.splice(this.index + 1)
    this.states.push(snapshot)
    if (this.states.length > 100) this.states.shift()
    this.index = this.states.length - 1
  }

  hasToken(token: string): boolean {
    return this.states.some((state) => state.text.includes(token))
  }

  settle(token: string, text: string): DraftSnapshot {
    this.states = this.states.map((state) => {
      const at = state.text.indexOf(token)
      return at < 0 ? state : splice(state, at, at + token.length, text)
    })
    const compact: DraftSnapshot[] = []
    let index = 0
    for (const [at, state] of this.states.entries()) {
      if (compact[compact.length - 1]?.text === state.text) compact[compact.length - 1] = state
      else compact.push(state)
      if (at === this.index) index = compact.length - 1
    }
    this.states = compact
    this.index = index
    return this.states[this.index]!
  }

  undo(): DraftSnapshot {
    if (this.index > 0) this.index -= 1
    return this.states[this.index]!
  }

  redo(): DraftSnapshot {
    if (this.index < this.states.length - 1) this.index += 1
    return this.states[this.index]!
  }

  reset(): void {
    this.states = [{ text: "", cursor: 0 }]
    this.index = 0
  }
}
