#!/usr/bin/env python3
# Régénère Sources/Prism/Features/Emoji/EmojiData.swift.
# Usage : python3 scripts/generate-emoji-data.py Sources/Prism/Features/Emoji/EmojiData.swift <emoji-toolkit>/emoji.json
# Les noms anglais et français viennent du système (CoreEmoji) : la liste suit la version de macOS qui exécute le script.
# L’ordre, les catégories, les tons de peau et les mots-clés anglais viennent d’emoji-toolkit (npm, licence MIT).
import json, plistlib, re, sys
R='/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/'
en=plistlib.load(open(R+'en.lproj/AppleName.strings','rb'))
fr=plistlib.load(open(R+'fr.lproj/AppleName.strings','rb'))
vfr=plistlib.load(open(R+'fr.lproj/Voiceover.strings','rb'))
ven=plistlib.load(open(R+'en.lproj/Voiceover.strings','rb'))
d=json.load(open(sys.argv[2]))
def ch(cp): return ''.join(chr(int(x,16)) for x in cp.split('-'))
def strip(s): return s.replace('️','').replace('‍','')
def vkey(s):
    u=s.encode('utf-16-be').hex()
    return 'UnicodeHex.'+u
SMILEY_END=d['1f63e']['order']+1
tk={}
for k,v in d.items():
    if v['diversity'] is not None or v['category'] in ('regional','modifier'): continue
    key=strip(ch(v['code_points']['fully_qualified']))
    if key in tk and len(tk[key]['code_points']['fully_qualified'])>len(v['code_points']['fully_qualified']): continue
    tk[key]=v
catmap={'nature':'nature','food':'food','travel':'travel','activity':'activities','objects':'objects','symbols':'symbols','flags':'flags'}
manual={'\U0001f6d8':('travel',['landslide','rocks','disaster']),'\U0001fa8a':('objects',['trombone','music','instrument']),
 '\U0001fa8e':('objects',['treasure','chest','pirate','gold']),'\U0001fac8':('nature',['hairy','creature','bigfoot','yeti','monster']),
 '\U0001facd':('nature',['orca','killer','whale','ocean']),'\U0001faea':('smileys',['distorted','face','dizzy','confused']),
 '\U0001faef':('smileys',['fight','cloud','fight','argue','brawl']),'🧑‍🩰':('people',['ballet','dancer','dance'])}
tones=['\U0001F3FB','\U0001F3FC','\U0001F3FD','\U0001F3FE','\U0001F3FF']
modbases=set()
for v in d.values():
    if v['diversity'] is None and v['diversity_children'] and '-' not in v['code_points']['base']:
        modbases.add(ch(v['code_points']['base']))
rows=[]; seen=set(); problems=[]
order_extra=100000
for e,name_en in en.items():
    if '@' in e or e=='🫱‍🫲': continue
    key=strip(e)
    v=tk.get(key)
    if v is None:
        # séquences de couple sans ZWJ dans la boîte à outils
        if e in manual:
            cat,kw=manual[e]; order=order_extra; order_extra+=1; tone=0
        elif '🤝' in e:
            v=tk.get(strip(e)) or None
            cat='people'; kw=['holding','hands','couple']; order=SMILEY_END+1500; tone=1
        else:
            problems.append(e); continue
    if v is not None:
        c=v['category']
        cat=('smileys' if v['order']<SMILEY_END else 'people') if c=='people' else catmap[c]
        kw=[k for k in v['keywords'] if not re.fullmatch(r'uc\d+',k)]
        for sn in [v['shortname']]+v['shortname_alternates']:
            kw+=sn.strip(':').split('_')
        order=v['order']
        tone=1 if v['diversity_children'] else 0
    if tone:
        # vérifie la règle : modificateur après chaque base, FE0F retiré
        for t in tones:
            out=''; i=0; s=e
            while i<len(s):
                c=s[i]; out+=c
                if c in modbases and not (c=='\U0001F91D' and len(s)>1):
                    out+=t
                    if i+1<len(s) and s[i+1]=='️': i+=1
                i+=1
            if v is not None:
                kids={strip(ch(x)) for x in v['diversity_children']}
                if strip(out) not in kids: problems.append(('tone',e,out)); tone=0; break
    nfr=fr.get(e, name_en)
    vf=vfr.get(vkey(e)); ve=ven.get(vkey(e))
    kwfr=[]
    if vf and vf.lower()!=nfr.lower(): kwfr.append(vf)
    if ve and ve.lower()!=name_en.lower(): kw.append(ve)
    if v is not None and v['name'].lower()!=name_en.lower(): kw.append(v['name'])
    def clean(lst):
        out=[]; s=set()
        for k in lst:
            k=k.replace('\t',' ').replace('|',' ').strip().lower()
            if k and k not in s: s.add(k); out.append(k)
        return out
    rows.append((order,e,cat,tone,name_en,nfr,clean(kw),clean(kwfr)))
rows.sort(key=lambda r:r[0])
print('problems',problems, file=sys.stderr)
from collections import Counter
print(Counter(r[2] for r in rows), len(rows), sum(r[3] for r in rows), file=sys.stderr)
lines=['\t'.join([e,cat,str(t),n,f,'|'.join(k),'|'.join(kf)]) for _,e,cat,t,n,f,k,kf in rows]
body='\n'.join(lines)
assert '"""#' not in body
swift = '''// Généré depuis les noms d’Apple (CoreEmoji, anglais et français) et l’ordre du sélecteur d’emojis
// (Unicode, catégories et mots-clés d’emoji-toolkit, licence MIT). Ne pas modifier à la main.
// Une ligne par emoji : caractère, catégorie, ton de peau (1 si possible), nom anglais, nom français,
// mots-clés anglais puis français séparés par « | ».

enum EmojiData {
    static let table = #"""
''' + body + '''
"""#
}
'''
open(sys.argv[1],'w').write(swift)
