#!/usr/bin/env python3
"""Rebuild the bundled offline models from pinned public safetensors.

Run in a separate environment with content-model-requirements.txt. No game image
or user data is sent anywhere. Source files are checked before loading. Exports
are written only to --output, never over the committed models automatically.
"""
import argparse,hashlib,json,urllib.request
from pathlib import Path
import numpy as np
import torch,timm,open_clip,coremltools as ct
from safetensors.torch import load_file
from PIL import Image

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();repo=Path(__file__).resolve().parents[1]
manifest=json.loads((repo/'models/manifest.json').read_text())
args.cache.mkdir(parents=True,exist_ok=True);args.output.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(4);torch.manual_seed(101);torch.backends.mha.set_fastpath_enabled(False)

def source(entry):
    path=args.cache/(entry['name']+'-'+entry['source_filename'])
    if not path.exists():
        url=f"https://huggingface.co/{entry['repository']}/resolve/{entry['revision']}/{entry['source_filename']}"
        urllib.request.urlretrieve(url,path)
    if hashlib.sha256(path.read_bytes()).hexdigest()!=entry['source_sha256']:
        raise SystemExit('Source checksum mismatch: '+str(path))
    return path

class Adult(torch.nn.Module):
    def __init__(self,path):
        super().__init__();self.net=timm.create_model('vit_tiny_patch16_384',pretrained=False,num_classes=2)
        self.net.load_state_dict(load_file(str(path)))
    def forward(self,image):return torch.softmax(self.net(image),dim=1)

class VisionBody(torch.nn.Module):
    """Fixed-shape CLIP ViT-B/32 math, checked against the original image encoder."""
    def __init__(self,visual):
        super().__init__();self.conv=visual.conv1;self.cls=visual.class_embedding;self.pos=visual.positional_embedding
        self.pre=visual.ln_pre;self.post=visual.ln_post;self.blocks=visual.transformer.resblocks;self.proj=visual.proj
    def forward(self,image):
        x=self.conv(image).flatten(2).transpose(1,2)
        token=torch.zeros_like(x[:,:1,:])+self.cls.reshape(1,1,768)
        x=self.pre(torch.cat([token,x],dim=1)+self.pos)
        for block in self.blocks:
            q,k,v=torch.nn.functional.linear(block.ln_1(x),block.attn.in_proj_weight,block.attn.in_proj_bias).chunk(3,dim=-1)
            q=q.reshape(1,50,12,64).transpose(1,2);k=k.reshape(1,50,12,64).transpose(1,2);v=v.reshape(1,50,12,64).transpose(1,2)
            weights=torch.softmax((q@k.transpose(-2,-1))*.125,dim=-1)
            attention=(weights@v).transpose(1,2).reshape(1,50,768)
            x=x+torch.nn.functional.linear(attention,block.attn.out_proj.weight,block.attn.out_proj.bias)
            x=x+block.mlp(block.ln_2(x))
        return self.post(x[:,0,:])@self.proj

class Harm(torch.nn.Module):
    def __init__(self,path):
        super().__init__()
        model,_,_=open_clip.create_model_and_transforms('ViT-B-32',pretrained=None,force_quick_gelu=True)
        model.load_state_dict(load_file(str(path)));model.eval();self.visual=VisionBody(model.visual)
        tokenizer=open_clip.get_tokenizer('ViT-B-32');prompts=json.loads((repo/'models/harm-prompts.json').read_text())
        vectors=[]
        with torch.no_grad():
            image=torch.rand(1,3,224,224)
            assert (self.visual(image)-model.encode_image(image)).abs().max().item()<.0001
            for group in ['safe','harm']:
                encoded=model.encode_text(tokenizer(prompts[group]));encoded=encoded/encoded.norm(dim=-1,keepdim=True)
                mean=encoded.mean(dim=0);vectors.append(mean/mean.norm())
        self.register_buffer('prototypes',torch.stack(vectors).T);self.scale=prompts['temperature_scale']
        self.register_buffer('mean',torch.tensor([.48145466,.4578275,.40821073]).reshape(1,3,1,1))
        self.register_buffer('std',torch.tensor([.26862954,.26130258,.27577711]).reshape(1,3,1,1))
    def forward(self,image):
        feature=self.visual((image-self.mean)/self.std);feature=feature/feature.norm(dim=-1,keepdim=True)
        return torch.softmax(self.scale*feature@self.prototypes,dim=-1)

reports=[]
for entry,side,scale,bias in [(manifest['models'][0],384,2/255,[-1.]*3),(manifest['models'][1],224,1/255,[0.]*3)]:
    path=source(entry);net=(Adult(path) if entry['name']=='AdultContent' else Harm(path)).eval()
    example=torch.rand(1,3,side,side)
    with torch.no_grad():traced=torch.jit.trace(net,example)
    model=ct.convert(traced,inputs=[ct.ImageType(name='image',shape=example.shape,color_layout=ct.colorlayout.RGB,scale=scale,bias=bias)],outputs=[ct.TensorType(name='scores')],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16)
    if entry['name']=='HarmContent':
        config=ct.optimize.coreml.OptimizationConfig(global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode='linear_symmetric',dtype=np.int8))
        model=ct.optimize.coreml.linear_quantize_weights(model,config=config)
    model.license=entry['license'];model.author=entry.get('original_author','Marqo');model.version='1'
    model.short_description=entry['name']+' offline content-filter model; experimental pixel-art support'
    model.save(args.output/(entry['name']+'.mlpackage'))
    rgb=np.random.default_rng(101).integers(0,256,(side,side,3),dtype=np.uint8)
    normalized=torch.from_numpy(rgb.transpose(2,0,1).copy()).float().unsqueeze(0)*scale+torch.tensor(bias).reshape(1,3,1,1)
    with torch.no_grad():expected=net(normalized).numpy()
    actual=model.predict({'image':Image.fromarray(rgb)})['scores'];error=float(np.max(np.abs(expected-actual)))
    assert error<(.025 if entry['name']=='AdultContent' else .08)
    reports.append({'model':entry['name'],'maximum_absolute_output_error':error})
(args.output/'conversion-checks.json').write_text(json.dumps(reports,indent=2)+'\n')
print(json.dumps(reports,indent=2))
