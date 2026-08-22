// The remembered subtitle track, restored once — and the ring that used to overflow the
// stack proven broken. See modules/playback/subtitle-restore.js for the log evidence.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { subtitleRestoreTarget, trackLabel } from '../../../common/modules/playback/subtitle-restore.js'

const headers = []
headers[1] = { number: 1, language: 'eng', type: 'ass', name: 'Full' }
headers[2] = { number: 2, language: 'eng', type: 'ass', name: 'Signs & Songs' }

const exact = (remembered, label) => remembered === label

test('a remembered track is found by the label the picker showed', () => {
  assert.equal(subtitleRestoreTarget({ headers, remembered: 'eng - Signs & Songs', matches: exact }), 2)
  assert.equal(trackLabel(headers[1], headers), 'eng - Full')
})

test('an unlabelled track is described as english only when nothing else is', () => {
  const single = [null, { number: 1, type: 'ass' }]
  assert.equal(trackLabel(single[1], single), 'eng')
  const beside = [null, { number: 1, language: 'eng' }, { number: 2, type: 'ass' }]
  assert.equal(trackLabel(beside[2], beside), 'ass')
})

test('OFF is a restore too, but only once tracks exist to turn off', () => {
  assert.equal(subtitleRestoreTarget({ headers, remembered: 'OFF', matches: exact }), -1)
  assert.equal(subtitleRestoreTarget({ headers: [], remembered: 'OFF', matches: exact }), null)
})

test('nothing remembered, nothing matching, and nothing known are all "do nothing"', () => {
  assert.equal(subtitleRestoreTarget({ headers, matches: exact }), null)
  assert.equal(subtitleRestoreTarget({ headers, remembered: 'fre', matches: exact }), null)
  assert.equal(subtitleRestoreTarget({ headers: undefined, remembered: 'eng - Full', matches: exact }), null)
})

test('a restore that already happened is not asked for again — this is the recursion guard', () => {
  assert.equal(subtitleRestoreTarget({ headers, remembered: 'eng - Full', restored: true, matches: exact }), null)
  assert.equal(subtitleRestoreTarget({ headers, remembered: 'OFF', restored: true, matches: exact }), null)
})

test('the player loop that overflowed the stack now terminates', () => {
  // exactly the shape of PlayerPage: selecting a track announces it, which checks again
  let restored = false
  let selected = null
  let selections = 0
  const check = () => {
    const target = subtitleRestoreTarget({ headers, remembered: 'eng - Full', restored, matches: exact })
    if (target == null) return
    restored = true
    selectCaptions(target)
  }
  const selectCaptions = target => {
    if (++selections > 10) throw new Error('selectCaptions recursed — the ring is not broken')
    selected = target
    check() // Subtitles.selectCaptions calls onHeader, which is handleHeaders, which checks
  }
  check()
  assert.equal(selected, 1)
  assert.equal(selections, 1, 'the remembered track is selected exactly once per file')
})
