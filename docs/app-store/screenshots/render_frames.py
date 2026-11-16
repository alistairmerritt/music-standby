"""Sharper copies of the website's iPhone 18 Pro frames, for the App Store
canvas, rendered by the site's own phone.py with the site's settings."""
import sys, json
sys.path.insert(0, sys.argv[1])
import phone, watch
phone.P['f0'] = watch.ENV['f0']
scale = 16
im, info = phone.render(scale=scale, ss=2, margin=0.7, frame=True)
im.save('frame-portrait.png')
im2, _ = phone.render(scale=scale, ss=2, margin=0.7, frame=True, landscape=True)
im2 = im2.rotate(90, expand=True)
im2.save('frame-landscape.png')
print(im.size, im2.size, type(info))
