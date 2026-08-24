import { describe, expect, test } from 'bun:test'
import { railCover } from '@/modules/util.js'

const cover = { extraLarge: 'xl', large: 'large', medium: 'medium' }

describe('rail cover sizing', () => {
  test('standard-density rails decode the near-render-size image first', () => {
    expect(railCover(cover, 1)).toEqual(['large', 'xl', 'medium'])
    expect(railCover(cover, 1.5)).toEqual(['large', 'xl', 'medium'])
  })

  test('high-density rails keep the sharper source and every fallback', () => {
    expect(railCover(cover, 2)).toEqual(['xl', 'large', 'medium'])
    expect(railCover(undefined, 1)).toEqual([undefined, undefined, undefined])
  })
})
