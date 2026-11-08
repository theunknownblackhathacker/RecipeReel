import asyncio, sys, base64
from playwright.async_api import async_playwright

def glyph(fill):
    # A bowl with a play triangle cut out of it, and two wisps of steam: "video → food".
    return f'''
  <defs>
    <mask id="cut">
      <rect width="1024" height="1024" fill="white"/>
      <path d="M470 545 L470 685 Q470 705 488 696 L604 628 Q620 615 604 602 L488 534 Q470 525 470 545 Z" fill="black"/>
    </mask>
  </defs>
  <g mask="url(#cut)" fill="{fill}">
    <path d="M222 470 H802 Q818 470 816 486 C800 650 672 770 512 770 C352 770 224 650 208 486 Q206 470 222 470 Z"/>
    <rect x="402" y="782" width="220" height="34" rx="17"/>
  </g>
  <g fill="none" stroke="{fill}" stroke-width="34" stroke-linecap="round">
    <path d="M432 390 C402 350 462 320 432 270"/>
    <path d="M592 390 C562 350 622 320 592 270"/>
  </g>'''

LIGHT = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#FF8A4C"/><stop offset="1" stop-color="#E5423A"/></linearGradient></defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>{glyph("#FFFFFF")}</svg>'''

DARK = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1" gradientUnits="userSpaceOnUse" x1="200" y1="270" x2="820" y2="820">
    <stop offset="0" stop-color="#FF9A5E"/><stop offset="1" stop-color="#F0503F"/></linearGradient></defs>
  {glyph("url(#g)")}</svg>'''.replace('x1="0" y1="0" x2="1" y2="1" ', '')

TINTED = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{glyph("#FFFFFF")}</svg>'''

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        page = await b.new_page(viewport={"width": 1024, "height": 1024})
        for name, svg in [("AppIcon", LIGHT), ("AppIcon-Dark", DARK), ("AppIcon-Tinted", TINTED)]:
            open(name + ".svg", "w").write(svg)
            await page.set_content(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
            await page.locator("svg").screenshot(path=name + ".png", omit_background=True)
        # Preview: light and dark as they'd look on the home screen.
        tiles = ''.join(f'''<div style="text-align:center;margin:30px;font:600 26px -apple-system,Helvetica;color:{c}">
            <div style="width:300px;height:300px;border-radius:68px;overflow:hidden;background:{bg};box-shadow:0 8px 30px rgba(0,0,0,.25)">
            <img src="data:image/png;base64,{base64.b64encode(open(f,"rb").read()).decode()}" style="width:300px;height:300px"></div><div style="margin-top:14px">RecipeReel</div></div>'''
            for f, bg, c in [("AppIcon.png", "none", "#222"), ("AppIcon-Dark.png", "linear-gradient(#2a2a2c,#111)", "#222"),
                             ("AppIcon-Tinted.png", "linear-gradient(#3b2f22,#1a140e)", "#222")])
        await page.set_viewport_size({"width": 1140, "height": 460})
        await page.set_content(f'<html><body style="margin:0;display:flex;justify-content:center;background:#e9e6e1">{tiles}</body></html>')
        await page.screenshot(path="preview.png")
        await b.close()
asyncio.run(main())
