# Third-party notices

## Land bitmap

`Sources/SonataCore/LandMaskData.swift` embeds the 0.5° land bitmap from
[topophany](https://github.com/WhitenWhiten/topophany) (`internal/tui/land.bin`), rasterized
from [Natural Earth](https://www.naturalearthdata.com) 1:110m land polygons, which are in the
public domain.

```
MIT License

Copyright (c) 2026 Topophany contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Design

The panel's look (cards on glass, the dithered land matrix, folded map seams) follows the
Native theme of [topophany-bar](https://github.com/WhitenWhiten/topophany-bar). No
topophany-bar code is included in Sonata.

## The Solana mark

The Solana logo is a trademark of the Solana Foundation, used here to identify the network.

## Data

Sonata reads public data at runtime; none of it is redistributed in this repository.

- Epoch rewards: **Fueled by [Trillium](https://trillium.so)**, under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- MEV rewards: [Jito](https://www.jito.network)'s public API.
- Block-building scores: [ibrl.wtf](https://ibrl.wtf), via `explorer.bam.dev`.
- IP locations: [ip-api.com](https://ip-api.com).
- Validator names and icons: published on-chain by each validator with
  `solana validator-info publish`.
