// Ambil atau buat container toast
function getToastContainer() {
  let el = document.getElementById('gi-toast')
  if (!el) {
    el = document.createElement('div')
    el.id = 'gi-toast'
    el.style.cssText = `
      position:fixed;bottom:24px;left:50%;transform:translateX(-50%);
      z-index:9999;display:flex;flex-direction:column;gap:8px;
      width:calc(100% - 48px);max-width:380px;pointer-events:none;
    `
    document.body.appendChild(el)
  }
  return el
}

// Toast notifikasi ramah
export function toast(pesan, tipe = 'info') {
  const warna = { sukses: '#1D9E75', error: '#E53E3E', info: '#534AB7', peringatan: '#D69E2E' }
  const el = document.createElement('div')
  el.style.cssText = `
    background:${warna[tipe] || warna.info};color:white;
    padding:12px 16px;border-radius:12px;font-size:14px;
    font-family:Nunito,sans-serif;font-weight:500;line-height:1.4;
    box-shadow:0 4px 12px rgba(0,0,0,0.15);pointer-events:auto;
    opacity:0;transform:translateY(8px);transition:all 0.25s ease;
  `
  el.textContent = pesan
  getToastContainer().appendChild(el)

  requestAnimationFrame(() => {
    el.style.opacity = '1'
    el.style.transform = 'translateY(0)'
  })
  setTimeout(() => {
    el.style.opacity = '0'
    el.style.transform = 'translateY(8px)'
    setTimeout(() => el.remove(), 260)
  }, 3500)
}

// Loading overlay
export function loading(tampil, pesan = 'Sebentar ya...') {
  const id = 'gi-loading'
  if (tampil) {
    if (document.getElementById(id)) return
    const el = document.createElement('div')
    el.id = id
    el.style.cssText = `
      position:fixed;inset:0;background:rgba(255,255,255,0.88);
      z-index:9997;display:flex;flex-direction:column;
      align-items:center;justify-content:center;gap:12px;
    `
    el.innerHTML = `
      <div style="width:40px;height:40px;border:3px solid #E9E8FC;
        border-top-color:#534AB7;border-radius:50%;
        animation:gi-spin 0.8s linear infinite"></div>
      <p style="font-family:Nunito,sans-serif;color:#534AB7;
        font-size:14px;margin:0">${pesan}</p>
    `
    document.body.appendChild(el)
  } else {
    document.getElementById(id)?.remove()
  }
}

// Modal konfirmasi bawah layar (bukan alert!)
export function konfirmasi(opsi) {
  return new Promise(resolve => {
    const overlay = document.createElement('div')
    overlay.style.cssText = `
      position:fixed;inset:0;background:rgba(0,0,0,0.45);
      z-index:9998;display:flex;align-items:flex-end;
      justify-content:center;padding:0 16px 24px;
    `
    const modal = document.createElement('div')
    modal.style.cssText = `
      background:white;border-radius:20px;padding:24px;
      width:100%;max-width:400px;font-family:Nunito,sans-serif;
    `
    modal.innerHTML = `
      <h3 style="font-family:Poppins,sans-serif;font-size:16px;
        color:#2D3748;margin:0 0 8px">${opsi.judul || 'Konfirmasi'}</h3>
      <p style="font-size:14px;color:#718096;margin:0 0 20px;
        line-height:1.5">${opsi.pesan}</p>
      <div style="display:flex;gap:12px">
        <button id="gi-modal-batal" style="flex:1;padding:12px;
          border:1.5px solid #E2E8F0;border-radius:10px;background:white;
          font-size:14px;font-family:Nunito,sans-serif;color:#718096;
          cursor:pointer">${opsi.labelBatal || 'Batal'}</button>
        <button id="gi-modal-ok" style="flex:1;padding:12px;border:none;
          border-radius:10px;background:#534AB7;color:white;font-size:14px;
          font-family:Nunito,sans-serif;font-weight:600;
          cursor:pointer">${opsi.labelOk || 'Ya'}</button>
      </div>
    `
    overlay.appendChild(modal)
    document.body.appendChild(overlay)

    const tutup = (hasil) => { overlay.remove(); resolve(hasil) }
    document.getElementById('gi-modal-ok').onclick = () => tutup(true)
    document.getElementById('gi-modal-batal').onclick = () => tutup(false)
    overlay.onclick = (e) => { if (e.target === overlay) tutup(false) }
  })
}
