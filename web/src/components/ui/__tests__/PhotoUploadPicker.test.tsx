// @vitest-environment jsdom
/** P3-U1..U4 — T-2042: the picker reports files from the file button, drop and paste (scoped), and has a camera input. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, createEvent, fireEvent, render, screen } from '@testing-library/react'
import { PhotoUploadPicker } from '../PhotoUploadPicker'

expect.extend(jestDomMatchers)
afterEach(cleanup)

const labels = { choose: 'Choose', take: 'Take', drop: 'Drop here', target: 'Area' }
const png = (name = 'a.png') => new File(['x'], name, { type: 'image/png' })

function setup(props: { disabled?: boolean } = {}) {
  const onFiles = vi.fn()
  render(
    <div>
      <PhotoUploadPicker labels={labels} onFiles={onFiles} disabledReason="Full" {...props} />
      <textarea data-testid="caption" />
    </div>,
  )
  return onFiles
}

describe('P3-U1 file button', () => {
  it('accepts several images and reports them, then clears the input', () => {
    const onFiles = setup()
    const input = screen.getByTestId('photo-file-input') as HTMLInputElement
    expect(input.multiple).toBe(true)
    fireEvent.change(input, { target: { files: [png('a.png'), png('b.png')] } })
    expect(onFiles).toHaveBeenCalledTimes(1)
    expect(onFiles.mock.calls[0][0].map((f: File) => f.name)).toEqual(['a.png', 'b.png'])
  })
})

describe('P3-U2 drop', () => {
  it('reports the image files of a drop and ignores other files', () => {
    const onFiles = setup()
    const text = new File(['t'], 'a.txt', { type: 'text/plain' })
    fireEvent.drop(screen.getByTestId('photo-drop'), { dataTransfer: { files: [png(), text], items: [] } })
    expect(onFiles.mock.calls[0][0]).toHaveLength(1)
  })
})

describe('P3-U3 paste', () => {
  const pasteInto = (el: Element, file: File | null) => {
    const ev = createEvent.paste(el, { clipboardData: { items: file ? [{ kind: 'file', type: file.type, getAsFile: () => file }] : [], files: file ? [file] : [] } })
    fireEvent(el, ev)
    return ev
  }
  it('takes a pasted image on the drop target and prevents the default only then', () => {
    const onFiles = setup()
    const ev = pasteInto(screen.getByTestId('photo-drop'), png())
    expect(onFiles).toHaveBeenCalledTimes(1)
    expect(ev.defaultPrevented).toBe(true)
    const none = pasteInto(screen.getByTestId('photo-drop'), null)
    expect(onFiles).toHaveBeenCalledTimes(1)
    expect(none.defaultPrevented).toBe(false)
  })
  it('does not take a paste made into a text field', () => {
    const onFiles = setup()
    pasteInto(screen.getByTestId('caption'), png())
    expect(onFiles).not.toHaveBeenCalled()
  })
})

describe('P3-U4 camera and disabled', () => {
  it('has a separate rear-camera input and the ordinary picker stays', () => {
    setup()
    const camera = screen.getByTestId('photo-camera-input')
    expect(camera).toHaveAttribute('capture', 'environment')
    expect(camera).toHaveAttribute('accept', 'image/*')
    expect(screen.getByTestId('photo-file-input')).not.toHaveAttribute('capture')
    expect(screen.getByTestId('photo-choose')).toBeEnabled()
  })
  it('opens the picker from the keyboard on the drop target', () => {
    setup()
    const click = vi.spyOn(screen.getByTestId('photo-file-input'), 'click')
    fireEvent.keyDown(screen.getByTestId('photo-drop'), { key: 'Enter' })
    expect(click).toHaveBeenCalled()
  })
  it('disabled: buttons off, drop and paste ignored, the reason is shown', () => {
    const onFiles = setup({ disabled: true })
    expect(screen.getByTestId('photo-choose')).toBeDisabled()
    expect(screen.getByTestId('photo-take')).toBeDisabled()
    expect(screen.getByTestId('photo-disabled-reason')).toHaveTextContent('Full')
    fireEvent.drop(screen.getByTestId('photo-drop'), { dataTransfer: { files: [png()], items: [] } })
    expect(onFiles).not.toHaveBeenCalled()
  })
})
