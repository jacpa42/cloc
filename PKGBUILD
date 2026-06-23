# Maintainer: Jacob Enthoven <jacpa42@proton.me>

pkgname=cloc
pkgver=0.0.1
pkgrel=1
pkgdesc="Code line counter"
arch=('x86_64' 'aarch64' 'i686')
url="https://github.com/jacpa42/$pkgname"
license=('MIT')
makedepends=('git' 'odin' 'binutils')
source=("https://github.com/jacpa42/${pkgname}/archive/refs/tags/${pkgver}.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$srcdir/$pkgname-${pkgver}"
    odin build cloc.odin -file -out:cloc -o:speed -lto:thin -no-bounds-check -source-code-locations:none
    strip cloc
}

package() {
    cd "$srcdir/$pkgname-${pkgver}"
    install -Dm755 "$pkgname" "$pkgdir/usr/bin/$pkgname"
}
