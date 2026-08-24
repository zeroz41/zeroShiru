import { describe, expect, test } from 'bun:test'
import { requiresNativePlayback } from '@/modules/playback/transport.js'

describe('playback transport selection', () => {
  test('routes Linux Matroska files around WebKitGTK', () => {
    expect(requiresNativePlayback({ name: 'Episode 02.mkv' }, 'linux')).toBe(true)
    expect(requiresNativePlayback({ path: 'Season/Episode.MKV' }, 'linux')).toBe(true)
    expect(requiresNativePlayback({ type: 'video/x-matroska', url: 'https://cdn/file' }, 'linux')).toBe(true)
    expect(requiresNativePlayback({ url: 'https://cdn/file.mkv?token=signed' }, 'linux')).toBe(true)
  })

  test('keeps working embedded formats and other platforms in the webview', () => {
    expect(requiresNativePlayback({ name: 'Episode 02.mp4', type: 'video/mp4' }, 'linux')).toBe(false)
    expect(requiresNativePlayback({ name: 'Episode 02.mkv' }, 'windows')).toBe(false)
    expect(requiresNativePlayback({ name: 'Episode 02.mkv' }, 'darwin')).toBe(false)
    expect(requiresNativePlayback(null, 'linux')).toBe(false)
  })
})

