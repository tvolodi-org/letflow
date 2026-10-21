import type React from 'react'

export interface ConfirmPromoteModalProps {
  definitionName: string
  onConfirm: () => void
  onCancel: () => void
  isLoading: boolean
}

export function ConfirmPromoteModal(props: ConfirmPromoteModalProps): React.ReactElement {
  const { definitionName, onConfirm, onCancel, isLoading } = props

  return (
    <div
      data-testid="promote-confirm-modal"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'var(--surface-overlay)',
        zIndex: 'var(--z-modal)' as unknown as number,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          background: 'var(--surface-card)',
          borderRadius: '8px',
          padding: '1.5rem',
          maxWidth: '480px',
          width: '90vw',
          boxShadow: 'var(--shadow-modal-lg)',
        }}
      >
        <h3
          style={{
            margin: '0 0 1rem',
            fontSize: '1.05rem',
            fontWeight: 600,
            color: 'var(--text-primary)',
          }}
        >
          Promote to Production
        </h3>
        <p
          style={{
            margin: '0 0 1.5rem',
            fontSize: '.9rem',
            color: 'var(--color-neutral-700)',
            lineHeight: 1.55,
          }}
        >
          {`You are about to promote '${definitionName}' to production. This will create a DRAFT version that requires separate activation. Confirm?`}
        </p>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
          <button
            data-testid="promote-cancel-btn"
            type="button"
            onClick={onCancel}
            disabled={isLoading}
            style={{
              padding: '6px 16px',
              border: '1px solid var(--color-neutral-300)',
              borderRadius: '4px',
              background: 'var(--surface-card)',
              cursor: isLoading ? 'not-allowed' : 'pointer',
              fontSize: '.875rem',
              color: 'var(--color-neutral-700)',
              opacity: isLoading ? 0.6 : 1,
            }}
          >
            Cancel
          </button>
          <button
            data-testid="promote-confirm-btn"
            type="button"
            onClick={onConfirm}
            disabled={isLoading}
            style={{
              padding: '6px 16px',
              border: 'none',
              borderRadius: '4px',
              background: 'var(--interactive-danger)',
              color: 'var(--text-inverse)',
              cursor: isLoading ? 'not-allowed' : 'pointer',
              fontSize: '.875rem',
              fontWeight: 500,
              opacity: isLoading ? 0.7 : 1,
              display: 'flex',
              alignItems: 'center',
              gap: '.4rem',
            }}
          >
            {isLoading && (
              <svg
                aria-hidden="true"
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="3"
                style={{ animation: 'spin 1s linear infinite' }}
              >
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
            )}
            Confirm
          </button>
        </div>
      </div>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
    </div>
  )
}
