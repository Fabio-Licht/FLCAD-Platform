#include "native_viewport_host.h"

#include <d3dcompiler.h>
#include <DirectXMath.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <climits>
#include <cstring>
#include <map>
#include <stdexcept>
#include <tuple>

using Microsoft::WRL::ComPtr;
using namespace DirectX;

namespace {
const char *kShader = R"(
cbuffer Scene : register(b0) { row_major float4x4 mvp; float4 color; uint4 pick; uint4 managedFace; row_major float4x4 normalView; uint4 lighting; };
struct In { float3 p:POSITION; float3 n:NORMAL; };
struct Out { float4 p:SV_POSITION; float3 n:NORMAL; };
Out VSMain(In i) { Out o; o.p=mul(float4(i.p,1),mvp); o.n=mul(i.n,(float3x3)normalView); return o; }
float4 PSMain(Out i,uint primitiveId:SV_PrimitiveID):SV_TARGET {
 float3 n=normalize(i.n);
 // Rigid world-to-view rotation only: preserve oriented surface normals.
 // Bounded camera-linked lights; a back-facing normal keeps ambient light.
 float ambient=.42, key=.46, fill=.12;
 if (lighting.x > 0 && pick.x == 0) { ambient=.30; key=.54; fill=.16; }
 float d=ambient+key*saturate(dot(n,normalize(float3(-.22,.48,.78))))+
         fill*saturate(dot(n,normalize(float3(.66,-.28,.42))));
 float3 result=color.rgb*d;
 uint faceId=primitiveId+1;
 if(managedFace.y>0 && faceId>=managedFace.x && faceId<managedFace.x+managedFace.y)
   result=lerp(result,float3(0.18,0.82,1.0)*d,0.48);
 else if(managedFace.w>0 && faceId>=managedFace.z && faceId<managedFace.z+managedFace.w)
   result=lerp(result,float3(0.22,0.88,1.0)*d,0.22);
 else if(pick.y==1 && pick.z==faceId)
   result=lerp(result,float3(0.18,0.88,1.0)*d,0.24);
 return float4(result,color.a);
}
struct LineOut { float4 color:SV_TARGET; float depth:SV_Depth; };
LineOut PSLine(Out i) {
 LineOut o;
 if (pick.w == 2) {
   float3 n=normalize(i.n);
   float d=.42+.46*saturate(dot(n,normalize(float3(-.22,.48,.78))))+
           .12*saturate(dot(n,normalize(float3(.66,-.28,.42))));
   // CAD edges are black on the readable blue material. The alternate tone
   // is deterministic and only used when the shaded face is itself dark.
   o.color=float4(d < .58 ? float3(.72,.82,.90) : float3(.01,.015,.02),1);
 } else o.color=color;
 // Rasterizer depth bias does not affect LINELIST. Two D32 float steps,
 // only for shaded CAD edges; preserve wireframe depth exactly.
 uint depthBits=asuint(max(i.p.z,0));
 o.depth=asfloat(depthBits>pick.w ? depthBits-pick.w : 0);
 return o;
}
)";

const char *kPickShader = R"(
cbuffer Scene : register(b0) { row_major float4x4 mvp; float4 color; uint4 pick; uint4 managedFace; row_major float4x4 normalView; uint4 lighting; };
struct MeshIn { float3 p:POSITION; float3 n:NORMAL; };
struct PickIn { float3 p:POSITION; uint id:PICKID; };
struct Out { float4 p:SV_POSITION; nointerpolation uint id:PICKID; };
Out VSFace(MeshIn i) { Out o; o.p=mul(float4(i.p,1),mvp); o.id=0; return o; }
Out VSSubentity(PickIn i) { Out o; o.p=mul(float4(i.p,1),mvp); o.id=i.id; return o; }
uint4 PSFace(Out i,uint primitiveId:SV_PrimitiveID):SV_TARGET{return uint4(1,pick.x,primitiveId+1,1);}
uint4 PSEdge(Out i):SV_TARGET{return uint4(2,pick.x,i.id,1);}
uint4 PSVertex(Out i):SV_TARGET{return uint4(3,pick.x,i.id,1);}
float4 PSHover(Out i):SV_TARGET{return float4(0.12,0.92,1.0,1);}
)";

void Check(HRESULT value, const char *operation) {
  if (FAILED(value))
    throw std::runtime_error(operation);
}

const flutter::EncodableValue *Find(const flutter::EncodableMap &map,
                                    const char *key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

double Number(const flutter::EncodableValue& value) {
  if (const auto* v = std::get_if<double>(&value)) return *v;
  if (const auto* v = std::get_if<int64_t>(&value)) return static_cast<double>(*v);
  if (const auto* v = std::get_if<int32_t>(&value)) return static_cast<double>(*v);
  return 0;
}

void ReleaseFlutterTexture(void* context) {
  if (context) static_cast<ID3D11Texture2D*>(context)->Release();
}

}  // namespace

NativeViewportHost::NativeViewportHost(flutter::BinaryMessenger* messenger,
                                       flutter::TextureRegistrar* registrar)
    : registrar_(registrar) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "flcad/native_viewport",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });
}

NativeViewportHost::~NativeViewportHost() { Shutdown(); }

void NativeViewportHost::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    if (call.method_name() == "initialize") {
      const uint32_t width = arguments && Find(*arguments, "width")
          ? static_cast<uint32_t>(Number(*Find(*arguments, "width"))) : 1;
      const uint32_t height = arguments && Find(*arguments, "height")
          ? static_cast<uint32_t>(Number(*Find(*arguments, "height"))) : 1;
      if (const auto *lighting = Find(*arguments, "shadedLightingExperiment")) {
        if (const auto *value = std::get_if<bool>(lighting))
          shaded_lighting_experiment_ = *value;
      }
      Initialize(width, height);
      result->Success(flutter::EncodableValue(texture_id_));
    } else if (call.method_name() == "resize" && arguments) {
      Resize(static_cast<uint32_t>(Number(*Find(*arguments, "width"))),
             static_cast<uint32_t>(Number(*Find(*arguments, "height"))));
      result->Success();
    } else if ((call.method_name() == "snapshot" || call.method_name() == "delta") && arguments) {
      ApplySnapshot(*arguments, call.method_name() == "snapshot");
      result->Success(flutter::EncodableValue(scene_revision_));
    } else if (call.method_name() == "presentationEdges" && arguments) {
      ApplyPresentationEdges(*arguments);
      result->Success();
    } else if (call.method_name() == "remove" && arguments) {
      if (const auto* id = std::get_if<std::string>(Find(*arguments, "id"))) RemoveEntity(*id);
      result->Success();
    } else if (call.method_name() == "orbit" && arguments) {
      Orbit(Number(*Find(*arguments, "dx")), Number(*Find(*arguments, "dy"))); result->Success();
    } else if (call.method_name() == "pan" && arguments) {
      Pan(Number(*Find(*arguments, "dx")), Number(*Find(*arguments, "dy"))); result->Success();
    } else if (call.method_name() == "zoom" && arguments) {
      Zoom(Number(*Find(*arguments, "factor"))); result->Success();
    } else if (call.method_name() == "fit") {
      Fit(); Render(); result->Success();
    } else if (call.method_name() == "setCamera" && arguments) {
      SetCamera(*arguments); result->Success();
    } else if (call.method_name() == "textureProbe") {
      RenderTextureProbe(); result->Success();
    } else if (call.method_name() == "pick" && arguments) {
      const int x = static_cast<int>(Number(*Find(*arguments, "x")));
      const int y = static_cast<int>(Number(*Find(*arguments, "y")));
      std::scoped_lock lock(mutex_);
      const auto raw_pick = Pick(x, y); hover_ = {}; Render();
      result->Success(flutter::EncodableValue(EncodePick(raw_pick)));
    } else if (call.method_name() == "setManagedCadFaceHover" && arguments) {
      std::scoped_lock lock(mutex_);
      const auto *id = std::get_if<std::string>(Find(*arguments, "entityId"));
      const auto *sub_id = Find(*arguments, "presentationSubId");
      if (id && sub_id)
        SetManagedFaceHighlight(managed_face_hover_, *id,
                                static_cast<uint32_t>(Number(*sub_id)));
      Render();
      result->Success();
    } else if (call.method_name() == "setManagedCadFaceSelection" && arguments) {
      std::scoped_lock lock(mutex_);
      const auto *id = std::get_if<std::string>(Find(*arguments, "entityId"));
      const auto *sub_id = Find(*arguments, "presentationSubId");
      if (id && sub_id)
        SetManagedFaceHighlight(managed_face_selection_, *id,
                                static_cast<uint32_t>(Number(*sub_id)));
      Render();
      result->Success();
    } else if (call.method_name() == "clearManagedCadFaceSelection") {
      std::scoped_lock lock(mutex_);
      managed_face_selection_ = {};
      Render();
      result->Success();
    } else if (call.method_name() == "setOperationalHover" && arguments) {
      std::scoped_lock lock(mutex_); operational_hover_index_buffer_.Reset();
      operational_hover_index_count_=0; operational_hover_entity_id_.clear();operational_hover_id_.clear();
      const auto* id=std::get_if<std::string>(Find(*arguments,"entityId"));
      const auto* operational_id=std::get_if<std::string>(Find(*arguments,"operationalEntityId"));
      const auto* triangles=std::get_if<flutter::EncodableList>(Find(*arguments,"triangles"));
      if(id&&triangles){const auto found=entities_.find(*id);if(found!=entities_.end()){
        std::vector<uint32_t> indices;indices.reserve(triangles->size()*3);
        for(const auto& value:*triangles){const auto triangle=static_cast<size_t>(Number(value));const auto base=triangle*3;if(base+2<found->second.indices.size()){indices.push_back(found->second.indices[base]);indices.push_back(found->second.indices[base+1]);indices.push_back(found->second.indices[base+2]);}}
        if(!indices.empty()){D3D11_BUFFER_DESC descriptor{};descriptor.ByteWidth=static_cast<UINT>(indices.size()*sizeof(uint32_t));descriptor.Usage=D3D11_USAGE_IMMUTABLE;descriptor.BindFlags=D3D11_BIND_INDEX_BUFFER;D3D11_SUBRESOURCE_DATA source{indices.data()};Check(device_->CreateBuffer(&descriptor,&source,&operational_hover_index_buffer_),"operational hover IB");operational_hover_index_count_=static_cast<uint32_t>(indices.size());operational_hover_entity_id_=*id;if(operational_id)operational_hover_id_=*operational_id;}}}
      Render();result->Success();
    } else if (call.method_name() == "setOperationalSelection" && arguments) {
      std::scoped_lock lock(mutex_);operational_selection_index_buffer_.Reset();operational_selection_index_count_=0;operational_selection_entity_id_.clear();operational_selection_id_.clear();
      const auto* id=std::get_if<std::string>(Find(*arguments,"entityId"));const auto* triangles=std::get_if<flutter::EncodableList>(Find(*arguments,"triangles"));
      const auto* operational_id=std::get_if<std::string>(Find(*arguments,"operationalEntityId"));
      if(id&&triangles){const auto found=entities_.find(*id);if(found!=entities_.end()){std::vector<uint32_t> indices;indices.reserve(triangles->size()*3);for(const auto& value:*triangles){const auto triangle=static_cast<size_t>(Number(value));const auto base=triangle*3;if(base+2<found->second.indices.size()){indices.push_back(found->second.indices[base]);indices.push_back(found->second.indices[base+1]);indices.push_back(found->second.indices[base+2]);}}if(!indices.empty()){D3D11_BUFFER_DESC descriptor{};descriptor.ByteWidth=static_cast<UINT>(indices.size()*sizeof(uint32_t));descriptor.Usage=D3D11_USAGE_IMMUTABLE;descriptor.BindFlags=D3D11_BIND_INDEX_BUFFER;D3D11_SUBRESOURCE_DATA source{indices.data()};Check(device_->CreateBuffer(&descriptor,&source,&operational_selection_index_buffer_),"operational selection IB");operational_selection_index_count_=static_cast<uint32_t>(indices.size());operational_selection_entity_id_=*id;if(operational_id)operational_selection_id_=*operational_id;}}}
      Render();result->Success();
    } else if (call.method_name() == "clearOperationalSelection") {
      std::scoped_lock lock(mutex_);operational_selection_index_buffer_.Reset();operational_selection_index_count_=0;operational_selection_entity_id_.clear();operational_selection_id_.clear();Render();result->Success();
    } else if (call.method_name() == "clearHover") {
      std::scoped_lock lock(mutex_); hover_ = {}; managed_face_hover_ = {}; operational_hover_index_buffer_.Reset();operational_hover_index_count_=0;operational_hover_entity_id_.clear();operational_hover_id_.clear();Render(); result->Success();
    } else if (call.method_name() == "stats") {
      if (device_) Check(device_->GetDeviceRemovedReason(), "D3D device unavailable");
      result->Success(flutter::EncodableValue(Stats()));
    } else if (call.method_name() == "shutdown") {
      auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
      Shutdown([reply] { reply->Success(); });
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    result->Error("native_viewport", error.what());
  }
}

void NativeViewportHost::Initialize(uint32_t width, uint32_t height) {
  std::scoped_lock lock(mutex_);
  if (!device_) { CreateDevice(); CreatePipeline(); }
  CreateTarget(std::max(width, 1u), std::max(height, 1u));
  if (texture_id_ < 0) {
    const auto surface = surface_state_;
    flutter_texture_ = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [surface](size_t width, size_t height) { return surface->Describe(width, height); }));
    texture_id_ = registrar_->RegisterTexture(flutter_texture_.get());
    texture_registered_ = texture_id_ >= 0;
  }
  metric_start_ = std::chrono::steady_clock::now();
  callback_metric_start_ = metric_start_;
  Render();
}

void NativeViewportHost::CreateDevice() {
  UINT flags = 0;
#ifndef NDEBUG
  flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
  D3D_FEATURE_LEVEL level{};
  Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
      nullptr, 0, D3D11_SDK_VERSION, &device_, &level, &context_), "D3D11 device");
  ComPtr<IDXGIDevice> dxgi; ComPtr<IDXGIAdapter> adapter; DXGI_ADAPTER_DESC desc{};
  if (SUCCEEDED(device_.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter)) &&
      SUCCEEDED(adapter->GetDesc(&desc))) adapter_name_ = desc.Description;
}

void NativeViewportHost::CreatePipeline() {
  ComPtr<ID3DBlob> vs, ps, line, errors;
  Check(D3DCompile(kShader, std::strlen(kShader), nullptr, nullptr, nullptr,
      "VSMain", "vs_5_0", D3DCOMPILE_ENABLE_STRICTNESS, 0, &vs, &errors), "vertex shader");
  Check(D3DCompile(kShader, std::strlen(kShader), nullptr, nullptr, nullptr,
      "PSMain", "ps_5_0", D3DCOMPILE_ENABLE_STRICTNESS, 0, &ps, &errors), "pixel shader");
  Check(device_->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr,
      &vertex_shader_), "create VS");
  Check(device_->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr,
      &pixel_shader_), "create PS");
  Check(D3DCompile(kShader, std::strlen(kShader), nullptr, nullptr, nullptr,
                   "PSLine", "ps_5_0", D3DCOMPILE_ENABLE_STRICTNESS, 0, &line,
                   &errors),
        "line shader");
  Check(device_->CreatePixelShader(line->GetBufferPointer(),
                                   line->GetBufferSize(), nullptr,
                                   &line_shader_),
        "create line PS");
  const D3D11_INPUT_ELEMENT_DESC elements[] = {
    {"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},
    {"NORMAL",0,DXGI_FORMAT_R32G32B32_FLOAT,0,12,D3D11_INPUT_PER_VERTEX_DATA,0}};
  Check(device_->CreateInputLayout(elements, 2, vs->GetBufferPointer(), vs->GetBufferSize(),
      &input_layout_), "input layout");
  D3D11_BUFFER_DESC cb{}; cb.ByteWidth=sizeof(Constants); cb.Usage=D3D11_USAGE_DEFAULT;
  cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
  Check(device_->CreateBuffer(&cb,nullptr,&constants_),"constants");
  D3D11_RASTERIZER_DESC raster{}; raster.FillMode=D3D11_FILL_SOLID;
  raster.CullMode=D3D11_CULL_NONE; raster.DepthClipEnable=TRUE;
  Check(device_->CreateRasterizerState(&raster,&rasterizer_),"rasterizer");
  raster.DepthBias = -32;
  raster.SlopeScaledDepthBias = -0.5f;
  Check(device_->CreateRasterizerState(&raster, &edge_rasterizer_),
        "edge rasterizer");
  raster.DepthBias = 0;
  raster.SlopeScaledDepthBias = 0;
  raster.AntialiasedLineEnable = TRUE;
  Check(device_->CreateRasterizerState(&raster, &cad_edge_rasterizer_),
        "CAD edge rasterizer");
  D3D11_BLEND_DESC line_blend{};
  auto& line_target=line_blend.RenderTarget[0];
  line_target.BlendEnable=TRUE;line_target.SrcBlend=D3D11_BLEND_SRC_ALPHA;
  line_target.DestBlend=D3D11_BLEND_INV_SRC_ALPHA;line_target.BlendOp=D3D11_BLEND_OP_ADD;
  line_target.SrcBlendAlpha=D3D11_BLEND_ONE;line_target.DestBlendAlpha=D3D11_BLEND_INV_SRC_ALPHA;
  line_target.BlendOpAlpha=D3D11_BLEND_OP_ADD;line_target.RenderTargetWriteMask=D3D11_COLOR_WRITE_ENABLE_ALL;
  Check(device_->CreateBlendState(&line_blend,&cad_edge_blend_),"CAD line alpha blend");
  D3D11_DEPTH_STENCIL_DESC depth{}; depth.DepthEnable=TRUE;
  depth.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ALL; depth.DepthFunc=D3D11_COMPARISON_LESS;
  Check(device_->CreateDepthStencilState(&depth,&depth_state_),"depth state");
  depth.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ZERO;
  depth.DepthFunc=D3D11_COMPARISON_LESS_EQUAL;
  Check(device_->CreateDepthStencilState(&depth,&pick_overlay_depth_state_),"pick overlay depth state");
  ComPtr<ID3DBlob> pick_face_vs, pick_sub_vs, pick_face_ps, pick_edge_ps,
      pick_vertex_ps, hover_ps;
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "VSFace","vs_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&pick_face_vs,&errors),"pick face VS");
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "VSSubentity","vs_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&pick_sub_vs,&errors),"pick subentity VS");
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "PSFace","ps_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&pick_face_ps,&errors),"pick face PS");
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "PSEdge","ps_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&pick_edge_ps,&errors),"pick edge PS");
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "PSVertex","ps_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&pick_vertex_ps,&errors),"pick vertex PS");
  Check(D3DCompile(kPickShader,std::strlen(kPickShader),nullptr,nullptr,nullptr,
      "PSHover","ps_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&hover_ps,&errors),"hover PS");
  Check(device_->CreateVertexShader(pick_face_vs->GetBufferPointer(),pick_face_vs->GetBufferSize(),nullptr,&pick_face_vs_),"create pick face VS");
  Check(device_->CreateVertexShader(pick_sub_vs->GetBufferPointer(),pick_sub_vs->GetBufferSize(),nullptr,&pick_subentity_vs_),"create pick subentity VS");
  Check(device_->CreatePixelShader(pick_face_ps->GetBufferPointer(),pick_face_ps->GetBufferSize(),nullptr,&pick_face_ps_),"create pick face PS");
  Check(device_->CreatePixelShader(pick_edge_ps->GetBufferPointer(),pick_edge_ps->GetBufferSize(),nullptr,&pick_edge_ps_),"create pick edge PS");
  Check(device_->CreatePixelShader(pick_vertex_ps->GetBufferPointer(),pick_vertex_ps->GetBufferSize(),nullptr,&pick_vertex_ps_),"create pick vertex PS");
  Check(device_->CreatePixelShader(hover_ps->GetBufferPointer(),hover_ps->GetBufferSize(),nullptr,&hover_ps_),"create hover PS");
  const D3D11_INPUT_ELEMENT_DESC pick_elements[]={{"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},{"PICKID",0,DXGI_FORMAT_R32_UINT,0,12,D3D11_INPUT_PER_VERTEX_DATA,0}};
  Check(device_->CreateInputLayout(pick_elements,2,pick_sub_vs->GetBufferPointer(),pick_sub_vs->GetBufferSize(),&pick_input_layout_),"pick input layout");
}

void NativeViewportHost::CreateTarget(uint32_t width, uint32_t height) {
  width_=width; height_=height; target_view_.Reset(); target_texture_.Reset();
  shared_texture_handle_ = nullptr;
  depth_view_.Reset(); depth_texture_.Reset();
  pick_target_.Reset(); pick_texture_.Reset(); pick_readback_.Reset();
  D3D11_TEXTURE2D_DESC texture{}; texture.Width=width; texture.Height=height;
  texture.MipLevels=1; texture.ArraySize=1; texture.Format=DXGI_FORMAT_B8G8R8A8_UNORM;
  texture.SampleDesc.Count=1; texture.Usage=D3D11_USAGE_DEFAULT;
  texture.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
  texture.MiscFlags=D3D11_RESOURCE_MISC_SHARED;
  Check(device_->CreateTexture2D(&texture,nullptr,&target_texture_),"external texture");
  ComPtr<IDXGIResource> shared_resource;
  Check(target_texture_.As(&shared_resource), "external texture DXGI resource");
  Check(shared_resource->GetSharedHandle(&shared_texture_handle_),
        "external texture shared handle");
  Check(device_->CreateRenderTargetView(target_texture_.Get(),nullptr,&target_view_),"external RTV");
  texture.Format=DXGI_FORMAT_D32_FLOAT; texture.BindFlags=D3D11_BIND_DEPTH_STENCIL;
  texture.MiscFlags=0;
  Check(device_->CreateTexture2D(&texture,nullptr,&depth_texture_),"depth texture");
  Check(device_->CreateDepthStencilView(depth_texture_.Get(),nullptr,&depth_view_),"depth view");
  D3D11_TEXTURE2D_DESC pick{}; pick.Width=width; pick.Height=height;
  pick.MipLevels=1; pick.ArraySize=1; pick.Format=DXGI_FORMAT_R32G32B32A32_UINT;
  pick.SampleDesc.Count=1; pick.Usage=D3D11_USAGE_DEFAULT;
  pick.BindFlags=D3D11_BIND_RENDER_TARGET;
  Check(device_->CreateTexture2D(&pick,nullptr,&pick_texture_),"pick texture");
  Check(device_->CreateRenderTargetView(pick_texture_.Get(),nullptr,&pick_target_),"pick target");
  pick.Usage=D3D11_USAGE_STAGING; pick.BindFlags=0;
  pick.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  Check(device_->CreateTexture2D(&pick,nullptr,&pick_readback_),"pick readback");
  surface_descriptor_ = {sizeof(surface_descriptor_), target_texture_.Get(), width_, height_,
      width_, height_, kFlutterDesktopPixelFormatBGRA8888,
      ReleaseFlutterTexture, target_texture_.Get()};
  if (!surface_state_) surface_state_ = std::make_shared<SurfaceState>();
  std::scoped_lock surface_lock(surface_state_->mutex);
  surface_state_->texture = target_texture_;
  surface_state_->descriptor = surface_descriptor_;
  surface_state_->descriptor.handle = shared_texture_handle_;
  surface_state_->on_callback = [this](size_t w, size_t h) {
    ++texture_callbacks_; ++callback_window_count_;
    const auto now = std::chrono::steady_clock::now();
    const double elapsed = std::chrono::duration<double>(now - callback_metric_start_).count();
    if (elapsed >= 1) {
      texture_callback_hz_ = callback_window_count_ / elapsed;
      callback_window_count_ = 0; callback_metric_start_ = now;
    }
    last_requested_width_ = w; last_requested_height_ = h;
  };
}

void NativeViewportHost::Resize(uint32_t width, uint32_t height) {
  std::scoped_lock lock(mutex_);
  if (!device_ || (width_==width && height_==height)) return;
  CreateTarget(std::max(width,1u),std::max(height,1u)); Render();
}

void NativeViewportHost::ApplySnapshot(const flutter::EncodableMap& snapshot, bool replace) {
  const auto start=std::chrono::steady_clock::now(); std::scoped_lock lock(mutex_);
  const auto* raw_revision = Find(snapshot, "revision");
  const int64_t revision = raw_revision ? static_cast<int64_t>(Number(*raw_revision)) : 0;
  if (raw_revision && revision <= scene_revision_) return;
  if (replace) {
    entities_.clear();
    managed_face_hover_ = {};
    managed_face_selection_ = {};
  }
  const auto* raw=Find(snapshot,"entities");
  const auto* list=raw ? std::get_if<flutter::EncodableList>(raw) : nullptr;
  if (!list) return;
  for (const auto& value:*list) {
    const auto* map=std::get_if<flutter::EncodableMap>(&value); if(!map) continue;
    const auto* id=std::get_if<std::string>(Find(*map,"id"));
    if (!id) continue;
    if (const auto* removed = Find(*map, "removed");
        removed && std::holds_alternative<bool>(*removed) && std::get<bool>(*removed)) {
      entities_.erase(*id); continue;
    }
    const auto* nodes=std::get_if<flutter::EncodableList>(Find(*map,"nodes"));
    const auto* indices=std::get_if<flutter::EncodableList>(Find(*map,"triangles"));
    if (!nodes || !indices) {
      const auto existing = entities_.find(*id);
      if (existing != entities_.end() && Find(*map, "visible"))
        existing->second.visible = std::get<bool>(*Find(*map, "visible"));
      if (existing != entities_.end() && Find(*map, "selected"))
        existing->second.selected = std::get<bool>(*Find(*map, "selected"));
      continue;
    }
    if (Find(*map, "presentationLod")) {
      // STL LOD is checked in Dart before codec serialization, and again here
      // before CPU/GPU geometry allocation. Other approved CAD routes unchanged.
      if (nodes->size() > 125000 * 3 || indices->size() > 250000 * 3 ||
          nodes->size() % 3 || indices->size() % 3)
        throw std::runtime_error("STL presentation budget exceeded");
      for (const auto &raw_index : *indices) {
        const double index = Number(raw_index);
        if (!std::isfinite(index) || index < 0 ||
            index != std::floor(index) || index >= nodes->size() / 3)
          throw std::runtime_error("Invalid STL presentation index");
      }
    }
    if (nodes->size() < 3)
      continue;
    SceneEntity entity;
    entity.id = *id;
    if (const auto *color = Find(*map, "rootSrgb")) {
      const auto *rgb = std::get_if<flutter::EncodableList>(color);
      if (!rgb || rgb->size() != 3)
        throw std::runtime_error("Invalid root sRGB color");
      for (size_t i = 0; i < 3; ++i) {
        const double channel = Number((*rgb)[i]);
        if (!std::isfinite(channel) || channel < 0 || channel > 1)
          throw std::runtime_error("Invalid root sRGB channel");
        entity.root_srgb[i] = static_cast<float>(channel);
      }
    }
    entity.visible = Find(*map,"visible") ? std::get<bool>(*Find(*map,"visible")) : true;
    entity.selected = Find(*map,"selected") ? std::get<bool>(*Find(*map,"selected")) : false;
    entity.selection_preview =
        Find(*map, "selectionPreview") &&
        std::get<bool>(*Find(*map, "selectionPreview"));
    std::vector<XMFLOAT3> positions; positions.reserve(nodes->size()/3);
    for(size_t i=0;i+2<nodes->size();i+=3) positions.push_back({
      static_cast<float>(Number((*nodes)[i])),static_cast<float>(Number((*nodes)[i+1])),
      static_cast<float>(Number((*nodes)[i+2]))});
    const auto *normals =
        std::get_if<flutter::EncodableList>(Find(*map, "normals"));
    if (!normals || normals->size() != nodes->size())
      throw std::runtime_error("Invalid presentation normals");
    entity.vertices.resize(positions.size());
    for(size_t i=0;i<positions.size();++i) entity.vertices[i]={positions[i].x,positions[i].y,positions[i].z,0,0,0};
    entity.indices.reserve(indices->size());
    for(const auto& index:*indices) entity.indices.push_back(static_cast<uint32_t>(Number(index)));
    if (const auto *range_value = Find(*map, "faceTriangleRanges")) {
      const auto *ranges = std::get_if<flutter::EncodableList>(range_value);
      if (!ranges)
        throw std::runtime_error("Invalid managed CAD face ranges");
      uint32_t expected_first = 1;
      for (const auto &entry : *ranges) {
        const auto *range = std::get_if<flutter::EncodableList>(&entry);
        if (!range || range->size() != 2)
          throw std::runtime_error("Invalid managed CAD face range");
        const double first = Number((*range)[0]);
        const double count = Number((*range)[1]);
        if (!std::isfinite(first) || !std::isfinite(count) ||
            first != std::floor(first) || count != std::floor(count) ||
            first != expected_first || count < 0 ||
            first + count - 1 > entity.indices.size() / 3)
          throw std::runtime_error("Managed CAD face range is out of bounds");
        entity.face_triangle_ranges.emplace_back(
            static_cast<uint32_t>(first), static_cast<uint32_t>(count));
        expected_first += static_cast<uint32_t>(count);
      }
      if (expected_first != entity.indices.size() / 3 + 1)
        throw std::runtime_error("Managed CAD face ranges are incomplete");
    }
    for (size_t i = 0; i < entity.vertices.size(); ++i) {
      XMFLOAT3 n{static_cast<float>(Number((*normals)[i * 3])),
                 static_cast<float>(Number((*normals)[i * 3 + 1])),
                 static_cast<float>(Number((*normals)[i * 3 + 2]))};
      if (!std::isfinite(n.x) || !std::isfinite(n.y) || !std::isfinite(n.z))
        throw std::runtime_error("Invalid presentation normal");
      XMStoreFloat3(&n, XMVector3Normalize(XMLoadFloat3(&n)));
      entity.vertices[i].nx = n.x;
      entity.vertices[i].ny = n.y;
      entity.vertices[i].nz = n.z;
    }
    if (const auto *edge_value = Find(*map, "topologicalEdges")) {
      const auto *edges = std::get_if<flutter::EncodableList>(edge_value);
      if (!edges)
        throw std::runtime_error("Invalid display edges");
      for (const auto &entry : *edges) {
        const auto *points = std::get_if<flutter::EncodableList>(&entry);
        if (!points || points->size() < 6 || points->size() % 3)
          throw std::runtime_error("Invalid display edge polyline");
        for (size_t i = 3; i < points->size(); i += 3) {
          for (size_t j : {i - 3, i}) {
            Vertex v{static_cast<float>(Number((*points)[j])),
                     static_cast<float>(Number((*points)[j + 1])),
                     static_cast<float>(Number((*points)[j + 2])),
                     0,
                     0,
                     1};
            if (!std::isfinite(v.x) || !std::isfinite(v.y) ||
                !std::isfinite(v.z))
              throw std::runtime_error("Invalid display edge point");
            entity.display_edges.push_back(v);
          }
        }
      }
    }
    if (const auto *derived_value = Find(*map, "meshDerivedEdges")) {
      const auto *derived = std::get_if<flutter::EncodableMap>(derived_value);
      const auto *source = derived ? std::get_if<std::string>(
          Find(*derived, "source")) : nullptr;
      const auto *segments = derived ? std::get_if<flutter::EncodableList>(
          Find(*derived, "segments")) : nullptr;
      if (!source || *source != "meshDerived" || !segments ||
          segments->size() > 250000)
        throw std::runtime_error("Invalid mesh-derived edge payload");
      for (const auto &segment_value : *segments) {
        const auto *segment = std::get_if<flutter::EncodableMap>(&segment_value);
        const auto *segment_start = segment ? std::get_if<flutter::EncodableList>(
            Find(*segment, "start")) : nullptr;
        const auto *end = segment ? std::get_if<flutter::EncodableList>(
            Find(*segment, "end")) : nullptr;
        if (!segment || !segment_start || !end || segment_start->size() != 3 ||
            end->size() != 3)
          throw std::runtime_error("Invalid mesh-derived edge segment");
        const auto *kind = std::get_if<std::string>(Find(*segment, "kind"));
        if (!kind || (*kind != "openBoundary" && *kind != "crease" &&
                     *kind != "ambiguous"))
          throw std::runtime_error("Invalid mesh-derived edge kind");
        Vertex a{static_cast<float>(Number((*segment_start)[0])),
                 static_cast<float>(Number((*segment_start)[1])),
                 static_cast<float>(Number((*segment_start)[2])), 0, 0, 1};
        Vertex b{static_cast<float>(Number((*end)[0])),
                 static_cast<float>(Number((*end)[1])),
                 static_cast<float>(Number((*end)[2])), 0, 0, 1};
        for (const Vertex &v : {a, b}) {
          if (!std::isfinite(v.x) || !std::isfinite(v.y) ||
              !std::isfinite(v.z))
            throw std::runtime_error("Invalid mesh-derived edge point");
        }
        entity.mesh_derived_edges.push_back(a);
        entity.mesh_derived_edges.push_back(b);
      }
    }
    Upload(entity);
    entities_[*id] = std::move(entity);
    // A full geometry replacement invalidates renderer-local face identity.
    // Visibility/selection deltas take the no-nodes branch above and retain it.
    if (managed_face_hover_.entity_id == *id)
      managed_face_hover_ = {};
    if (managed_face_selection_.entity_id == *id)
      managed_face_selection_ = {};
  }
  // Dart owns the canonical pose. Scene/selection deltas must never refit it.
  if (raw_revision) scene_revision_ = revision;
  upload_ms_ = std::chrono::duration<double, std::milli>(
                   std::chrono::steady_clock::now() - start)
                   .count();
  Render();
}

void NativeViewportHost::Upload(SceneEntity& entity) {
  if(entity.vertices.empty()||entity.indices.empty())return;
  D3D11_BUFFER_DESC vb{};vb.ByteWidth=static_cast<UINT>(entity.vertices.size()*sizeof(Vertex));
  vb.Usage=D3D11_USAGE_IMMUTABLE;vb.BindFlags=D3D11_BIND_VERTEX_BUFFER;
  D3D11_SUBRESOURCE_DATA vd{entity.vertices.data()};Check(device_->CreateBuffer(&vb,&vd,&entity.vertex_buffer),"mesh VB");
  D3D11_BUFFER_DESC ib{};ib.ByteWidth=static_cast<UINT>(entity.indices.size()*sizeof(uint32_t));
  ib.Usage=D3D11_USAGE_IMMUTABLE;ib.BindFlags=D3D11_BIND_INDEX_BUFFER;
  D3D11_SUBRESOURCE_DATA data{entity.indices.data()};Check(device_->CreateBuffer(&ib,&data,&entity.index_buffer),"mesh IB");
  if (!entity.display_edges.empty()) {
    vb.ByteWidth =
        static_cast<UINT>(entity.display_edges.size() * sizeof(Vertex));
    D3D11_SUBRESOURCE_DATA edges{entity.display_edges.data()};
    Check(device_->CreateBuffer(&vb, &edges, &entity.display_edge_buffer),
          "CAD edges VB");
  }
  if (!entity.mesh_derived_edges.empty()) {
    vb.ByteWidth = static_cast<UINT>(
        entity.mesh_derived_edges.size() * sizeof(Vertex));
    D3D11_SUBRESOURCE_DATA edges{entity.mesh_derived_edges.data()};
    Check(device_->CreateBuffer(&vb, &edges, &entity.mesh_derived_edge_buffer),
          "mesh-derived edges VB");
  }
}

void NativeViewportHost::ApplyPresentationEdges(
    const flutter::EncodableMap& presentation) {
  std::scoped_lock lock(mutex_);
  for (auto &[id, entity] : entities_) {
    entity.mesh_silhouette_edges.clear();
    entity.mesh_silhouette_edge_buffer.Reset();
  }
  silhouette_accepted_segments_ = 0;
  silhouette_rejected_segments_ = 0;
  presentation_buffer_ = "none";
  const auto *entities = std::get_if<flutter::EncodableList>(
      Find(presentation, "entities"));
  if (!entities) {
    Render();
    return;
  }
  for (const auto &value : *entities) {
    const auto *map = std::get_if<flutter::EncodableMap>(&value);
    const auto *id = map ? std::get_if<std::string>(Find(*map, "id")) : nullptr;
    const auto *source = map ? std::get_if<std::string>(Find(*map, "source")) : nullptr;
    const auto *segments = map ? std::get_if<flutter::EncodableList>(
        Find(*map, "segments")) : nullptr;
    if (!id || !source || *source != "meshSilhouette" || !segments ||
        segments->size() > 250000) {
      silhouette_rejected_segments_ += segments ? segments->size() : 0;
      continue;
    }
    const auto found = entities_.find(*id);
    if (found == entities_.end()) {
      silhouette_rejected_segments_ += segments->size();
      continue;
    }
    auto &entity = found->second;
    for (const auto &segment_value : *segments) {
      const auto *segment = std::get_if<flutter::EncodableMap>(&segment_value);
      const auto *start = segment ? std::get_if<flutter::EncodableList>(
          Find(*segment, "start")) : nullptr;
      const auto *end = segment ? std::get_if<flutter::EncodableList>(
          Find(*segment, "end")) : nullptr;
      const auto *kind = segment ? std::get_if<std::string>(
          Find(*segment, "kind")) : nullptr;
      if (!segment || !start || !end || !kind || start->size() != 3 ||
          end->size() != 3 ||
          (*kind != "silhouette" && *kind != "openBoundary" &&
           *kind != "crease" && *kind != "ambiguous")) {
        ++silhouette_rejected_segments_;
        continue;
      }
      Vertex a{static_cast<float>(Number((*start)[0])),
               static_cast<float>(Number((*start)[1])),
               static_cast<float>(Number((*start)[2])), 0, 0, 1};
      Vertex b{static_cast<float>(Number((*end)[0])),
               static_cast<float>(Number((*end)[1])),
               static_cast<float>(Number((*end)[2])), 0, 0, 1};
      if (!std::isfinite(a.x) || !std::isfinite(a.y) ||
          !std::isfinite(a.z) || !std::isfinite(b.x) ||
          !std::isfinite(b.y) || !std::isfinite(b.z)) {
        ++silhouette_rejected_segments_;
        continue;
      }
      entity.mesh_silhouette_edges.push_back(a);
      entity.mesh_silhouette_edges.push_back(b);
      ++silhouette_accepted_segments_;
    }
    if (!entity.mesh_silhouette_edges.empty() && device_) {
      D3D11_BUFFER_DESC descriptor{};
      descriptor.ByteWidth = static_cast<UINT>(
          entity.mesh_silhouette_edges.size() * sizeof(Vertex));
      descriptor.Usage = D3D11_USAGE_IMMUTABLE;
      descriptor.BindFlags = D3D11_BIND_VERTEX_BUFFER;
      D3D11_SUBRESOURCE_DATA data{entity.mesh_silhouette_edges.data()};
      Check(device_->CreateBuffer(&descriptor, &data,
                                  &entity.mesh_silhouette_edge_buffer),
            "mesh-silhouette edges VB");
    }
  }
  Render();
}

void NativeViewportHost::SetManagedFaceHighlight(
    ManagedFaceHighlight &highlight, const std::string &entity_id,
    uint32_t presentation_sub_id) {
  const auto found = entities_.find(entity_id);
  if (found == entities_.end() || presentation_sub_id == 0) {
    highlight = {};
    return;
  }
  const auto &entity = found->second;
  const auto range = std::find_if(
      entity.face_triangle_ranges.begin(), entity.face_triangle_ranges.end(),
      [presentation_sub_id](const auto &candidate) {
        return presentation_sub_id >= candidate.first &&
               presentation_sub_id < candidate.first + candidate.second;
      });
  if (range == entity.face_triangle_ranges.end()) {
    highlight = {};
    return;
  }
  if (highlight.entity_id == entity_id &&
      highlight.first_triangle == range->first - 1 &&
      highlight.triangle_count == range->second)
    return;

  ManagedFaceHighlight next;
  next.entity_id = entity_id;
  next.first_triangle = range->first - 1;
  next.triangle_count = range->second;
  using Point = std::tuple<float, float, float>;
  using Edge = std::pair<Point, Point>;
  struct EdgeState {
    uint32_t count = 0;
    Vertex a{};
    Vertex b{};
  };
  std::map<Edge, EdgeState> edges;
  auto point = [](const Vertex &value) {
    return Point{value.x, value.y, value.z};
  };
  auto add_edge = [&](const Vertex &a, const Vertex &b) {
    auto first = point(a), second = point(b);
    if (second < first)
      std::swap(first, second);
    auto &state = edges[{first, second}];
    if (state.count++ == 0) {
      state.a = a;
      state.b = b;
    }
  };
  const size_t end = static_cast<size_t>(next.first_triangle +
                                         next.triangle_count);
  for (size_t triangle = next.first_triangle; triangle < end; ++triangle) {
    const size_t base = triangle * 3;
    if (base + 2 >= entity.indices.size()) {
      highlight = {};
      return;
    }
    const Vertex &a = entity.vertices[entity.indices[base]];
    const Vertex &b = entity.vertices[entity.indices[base + 1]];
    const Vertex &c = entity.vertices[entity.indices[base + 2]];
    add_edge(a, b);
    add_edge(b, c);
    add_edge(c, a);
  }
  std::vector<Vertex> boundary;
  for (const auto &[_, state] : edges) {
    if (state.count == 1) {
      boundary.push_back(state.a);
      boundary.push_back(state.b);
    }
  }
  if (!boundary.empty()) {
    D3D11_BUFFER_DESC descriptor{};
    descriptor.ByteWidth =
        static_cast<UINT>(boundary.size() * sizeof(Vertex));
    descriptor.Usage = D3D11_USAGE_IMMUTABLE;
    descriptor.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA source{boundary.data()};
    Check(device_->CreateBuffer(&descriptor, &source, &next.boundary_buffer),
          "managed CAD face boundary VB");
    next.boundary_vertex_count = static_cast<uint32_t>(boundary.size());
  }
  highlight = std::move(next);
}

void NativeViewportHost::Render() {
  if (device_) Check(device_->GetDeviceRemovedReason(), "D3D device unavailable");
  if(!target_view_)return;++render_calls_;const auto start=std::chrono::steady_clock::now();
  const float background[]{.075f,.095f,.115f,1};context_->ClearRenderTargetView(target_view_.Get(),background);
  context_->ClearDepthStencilView(depth_view_.Get(),D3D11_CLEAR_DEPTH,1,0);
  context_->OMSetRenderTargets(1,target_view_.GetAddressOf(),depth_view_.Get());
  D3D11_VIEWPORT vp{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};context_->RSSetViewports(1,&vp);
  const auto frame = camera_.BuildFrame(static_cast<float>(width_) / height_);
  Constants constants{};
  XMStoreFloat4x4(reinterpret_cast<XMFLOAT4X4*>(constants.matrix),
                  frame.world_view_projection);
  XMStoreFloat4x4(reinterpret_cast<XMFLOAT4X4*>(constants.normal_view),
                 frame.view);
  constants.color[0]=.30f;constants.color[1]=.50f;constants.color[2]=.68f;constants.color[3]=1;
  constants.lighting[0] = shaded_lighting_experiment_ ? 1u : 0u;
  constants.pick[0] = render_style_;
  UINT stride=sizeof(Vertex),offset=0;
  context_->IASetInputLayout(input_layout_.Get());context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context_->VSSetShader(vertex_shader_.Get(),nullptr,0);context_->VSSetConstantBuffers(0,1,constants_.GetAddressOf());context_->PSSetShader(pixel_shader_.Get(),nullptr,0);context_->PSSetConstantBuffers(0,1,constants_.GetAddressOf());
  context_->RSSetState(rasterizer_.Get());context_->OMSetDepthStencilState(depth_state_.Get(),0);triangles_=0;
  constants.color[3] = render_style_ == 3 ? .22f : 1.f;
  context_->OMSetBlendState(render_style_ == 3 ? cad_edge_blend_.Get() : nullptr, nullptr, UINT_MAX);
  if (render_style_ == 3) context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(), 0);
  for (auto &[id, e] : entities_) {
    if (!e.visible || !e.vertex_buffer || !e.index_buffer)
      continue;
    if (e.selection_preview)
      continue;
    if (render_style_ == 2)
      continue;
    std::copy(std::begin(e.root_srgb), std::end(e.root_srgb), constants.color);
    const bool has_managed_face_selection =
        id == managed_face_selection_.entity_id &&
        managed_face_selection_.valid();
    if (e.selected && !has_managed_face_selection) {
      constants.color[0] = .82f; constants.color[1] = .64f; constants.color[2] = .27f;
    }
    constants.pick[1] = id == hover_.entity_id ? hover_.kind : 0;
    constants.pick[2] = id == hover_.entity_id ? hover_.id : 0;
    constants.managed_face[0] = has_managed_face_selection
                                    ? managed_face_selection_.first_triangle + 1
                                    : 0;
    constants.managed_face[1] = has_managed_face_selection
                                    ? managed_face_selection_.triangle_count
                                    : 0;
    const bool has_managed_face_hover =
        id == managed_face_hover_.entity_id && managed_face_hover_.valid() &&
        (!has_managed_face_selection ||
         managed_face_hover_.first_triangle !=
             managed_face_selection_.first_triangle);
    constants.managed_face[2] = has_managed_face_hover
                                    ? managed_face_hover_.first_triangle + 1
                                    : 0;
    constants.managed_face[3] = has_managed_face_hover
                                    ? managed_face_hover_.triangle_count
                                    : 0;
    context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0, 0);
    ++constant_buffer_updates_;
    context_->IASetVertexBuffers(0, 1, e.vertex_buffer.GetAddressOf(), &stride,
                                 &offset);
    context_->IASetIndexBuffer(e.index_buffer.Get(), DXGI_FORMAT_R32_UINT, 0);
    context_->DrawIndexed(static_cast<UINT>(e.indices.size()), 0, 0);
    ++draw_indexed_calls_;
    triangles_ += e.indices.size() / 3;
  }
  silhouette_drawn_segments_ = 0;
  mesh_derived_drawn_segments_ = 0;
  display_edges_drawn_segments_ = 0;
  presentation_buffer_ = "none";
  if ((render_style_ == 1 || render_style_ == 2) && !(render_style_==1&&(operational_selection_index_buffer_||operational_hover_index_buffer_))) {
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
    context_->PSSetShader(line_shader_.Get(), nullptr, 0);
    context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(), 0);
    context_->RSSetState(render_style_ == 1 ? cad_edge_rasterizer_.Get()
                                             : edge_rasterizer_.Get());
    context_->OMSetBlendState(render_style_==1?cad_edge_blend_.Get():nullptr,nullptr,UINT_MAX);
    constants.color[0] = .01f;
    constants.color[1] = .015f;
    constants.color[2] = .02f;
    constants.color[3] = 1;
    if (render_style_ == 2) {
      constants.color[0] = .52f;
      constants.color[1] = .85f;
      constants.color[2] = .91f;
    }
    constants.pick[1] = constants.pick[2] = 0;
    constants.pick[3] = render_style_ == 1 ? 2 : 0;
    context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0, 0);
    const int offsets[][2] = {{0, 0}, {-1, 0}, {1, 0}, {0, -1}, {0, 1}};
    const int offset_count = 1; // One screen-pixel CAD line; never dilate contours.
    for (const auto &[id, e] : entities_) {
      ID3D11Buffer *edge_buffer =
          (render_style_ == 1 && e.mesh_silhouette_edge_buffer)
              ? e.mesh_silhouette_edge_buffer.Get()
              : (render_style_ == 1 && e.display_edge_buffer)
              ? e.display_edge_buffer.Get()
              : (render_style_ == 1 ? e.mesh_derived_edge_buffer.Get()
                                    : e.display_edge_buffer.Get());
      const auto edge_count =
          (render_style_ == 1 && !e.mesh_silhouette_edges.empty())
              ? e.mesh_silhouette_edges.size()
              : (render_style_ == 1 && !e.display_edges.empty())
              ? e.display_edges.size()
              : (render_style_ == 1 ? e.mesh_derived_edges.size()
                                    : e.display_edges.size());
      if (!e.visible || !edge_buffer || edge_count == 0)
        continue;
      if (render_style_ == 1 && e.mesh_silhouette_edge_buffer) {
        silhouette_drawn_segments_ += edge_count / 2;
        presentation_buffer_ = "meshSilhouette";
      } else if (render_style_ == 1 && e.display_edge_buffer) {
        display_edges_drawn_segments_ += edge_count / 2;
        if (presentation_buffer_ == "none") presentation_buffer_ = "topological";
      } else if (render_style_ == 1 && e.mesh_derived_edge_buffer) {
        mesh_derived_drawn_segments_ += edge_count / 2;
        if (presentation_buffer_ == "none") presentation_buffer_ = "meshDerived";
      }
      context_->IASetVertexBuffers(0, 1, &edge_buffer, &stride, &offset);
      if (render_style_ == 2) {
        const bool selected = e.selected || id == operational_selection_entity_id_;
        constants.color[0] = selected ? .92f : .52f;
        constants.color[1] = selected ? .69f : .85f;
        constants.color[2] = selected ? .26f : .91f;
        context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0, 0);
      }
      for (int pass = 0; pass < offset_count; ++pass) {
        if (pass != 0) {
          D3D11_VIEWPORT edge_viewport{
              static_cast<float>(offsets[pass][0]),
              static_cast<float>(offsets[pass][1]), static_cast<float>(width_),
              static_cast<float>(height_), 0, 1};
          context_->RSSetViewports(1, &edge_viewport);
        }
        context_->Draw(static_cast<UINT>(edge_count), 0);
      }
    }
    context_->RSSetViewports(1, &vp);
    context_->RSSetState(rasterizer_.Get());
    context_->OMSetBlendState(nullptr,nullptr,UINT_MAX);
  }
  // Recognition/brush selection is a transient overlay. It is drawn after
  // opaque geometry with depth-write disabled, so coplanar triangles do not
  // z-fight and the ice-white fill is not darkened by mesh lighting.
  for (auto &[id, e] : entities_) {
    if (!e.selection_preview || !e.visible || !e.vertex_buffer ||
        !e.index_buffer)
      continue;
    constants.color[0] = .9608f;
    constants.color[1] = .9686f;
    constants.color[2] = .9804f;
    constants.color[3] = 1.f;
    constants.lighting[0] = 0;
    constants.pick[0] = render_style_;
    constants.pick[1] = constants.pick[2] = constants.pick[3] = 0;
    std::fill(std::begin(constants.managed_face),
              std::end(constants.managed_face), 0);
    context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0, 0);
    context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(), 0);
    context_->OMSetBlendState(nullptr, nullptr, UINT_MAX);
    context_->IASetInputLayout(input_layout_.Get());
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->IASetVertexBuffers(0, 1, e.vertex_buffer.GetAddressOf(), &stride,
                                 &offset);
    context_->IASetIndexBuffer(e.index_buffer.Get(), DXGI_FORMAT_R32_UINT, 0);
    context_->VSSetShader(vertex_shader_.Get(), nullptr, 0);
    context_->PSSetShader(pixel_shader_.Get(), nullptr, 0);
    context_->DrawIndexed(static_cast<UINT>(e.indices.size()), 0, 0);
    if (e.display_edge_buffer && !e.display_edges.empty()) {
      context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
      context_->PSSetShader(line_shader_.Get(), nullptr, 0);
      context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(), 0);
      context_->IASetVertexBuffers(0, 1, e.display_edge_buffer.GetAddressOf(),
                                   &stride, &offset);
      context_->RSSetState(edge_rasterizer_.Get());
      constants.color[0] = .04f;
      constants.color[1] = .06f;
      constants.color[2] = .08f;
      constants.color[3] = 1.f;
      context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0,
                                  0);
      context_->Draw(static_cast<UINT>(e.display_edges.size()), 0);
      context_->RSSetState(cad_edge_rasterizer_.Get());
      constants.color[0] = 1.f;
      constants.color[1] = .749f;
      constants.color[2] = .271f;
      context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0,
                                  0);
      context_->Draw(static_cast<UINT>(e.display_edges.size()), 0);
    }
  }
  context_->RSSetState(rasterizer_.Get());
  context_->OMSetBlendState(nullptr,nullptr,UINT_MAX);
  if (render_style_ != 2) {
  std::fill(std::begin(constants.managed_face), std::end(constants.managed_face), 0);
  if(operational_selection_index_buffer_&&operational_selection_index_count_>0){auto found=entities_.find(operational_selection_entity_id_);if(found!=entities_.end()&&found->second.vertex_buffer){constants.color[0]=.92f;constants.color[1]=.38f;constants.color[2]=.04f;constants.pick[1]=0;constants.pick[2]=0;context_->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(),0);context_->IASetInputLayout(input_layout_.Get());context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context_->IASetVertexBuffers(0,1,found->second.vertex_buffer.GetAddressOf(),&stride,&offset);context_->IASetIndexBuffer(operational_selection_index_buffer_.Get(),DXGI_FORMAT_R32_UINT,0);context_->VSSetShader(vertex_shader_.Get(),nullptr,0);context_->PSSetShader(pixel_shader_.Get(),nullptr,0);context_->DrawIndexed(operational_selection_index_count_,0,0);}}
  if(operational_hover_id_!=operational_selection_id_&&operational_hover_index_buffer_&&operational_hover_index_count_>0){auto found=entities_.find(operational_hover_entity_id_);if(found!=entities_.end()&&found->second.vertex_buffer){constants.color[0]=.08f;constants.color[1]=.78f;constants.color[2]=.92f;constants.pick[1]=0;constants.pick[2]=0;context_->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(),0);context_->IASetInputLayout(input_layout_.Get());context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context_->IASetVertexBuffers(0,1,found->second.vertex_buffer.GetAddressOf(),&stride,&offset);context_->IASetIndexBuffer(operational_hover_index_buffer_.Get(),DXGI_FORMAT_R32_UINT,0);context_->VSSetShader(vertex_shader_.Get(),nullptr,0);context_->PSSetShader(pixel_shader_.Get(),nullptr,0);context_->DrawIndexed(operational_hover_index_count_,0,0);}}
  }
  // Selection fills are deliberately drawn over the material. Restore the
  // ordinary CAD contours afterwards so gold selection never hides topology.
  if(render_style_==1&&(operational_selection_index_buffer_||operational_hover_index_buffer_)){
    context_->IASetInputLayout(input_layout_.Get());context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
    context_->VSSetShader(vertex_shader_.Get(),nullptr,0);context_->PSSetShader(line_shader_.Get(),nullptr,0);
    context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(),0);context_->RSSetState(cad_edge_rasterizer_.Get());
    context_->OMSetBlendState(cad_edge_blend_.Get(),nullptr,UINT_MAX);
    constants.color[0]=.01f;constants.color[1]=.015f;constants.color[2]=.02f;constants.color[3]=1;constants.pick[1]=constants.pick[2]=0;constants.pick[3]=2;
    context_->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);
    const int offsets[][2]={{0,0}};
    for(const auto&[id,e]:entities_){if(!e.visible||!e.display_edge_buffer)continue;context_->IASetVertexBuffers(0,1,e.display_edge_buffer.GetAddressOf(),&stride,&offset);for(const auto&edge_offset:offsets){D3D11_VIEWPORT edge_viewport{static_cast<float>(edge_offset[0]),static_cast<float>(edge_offset[1]),static_cast<float>(width_),static_cast<float>(height_),0,1};context_->RSSetViewports(1,&edge_viewport);context_->Draw(static_cast<UINT>(e.display_edges.size()),0);}}
    context_->RSSetViewports(1,&vp);context_->RSSetState(rasterizer_.Get());
    context_->OMSetBlendState(nullptr,nullptr,UINT_MAX);
  }
  const auto draw_managed_face_boundary = [&](const ManagedFaceHighlight &face,
                                               bool selected) {
    if (!face.valid() || !face.boundary_buffer ||
        face.boundary_vertex_count == 0)
      return;
    const auto found = entities_.find(face.entity_id);
    if (found == entities_.end() || !found->second.visible)
      return;
    constants.color[0] = .18f;
    constants.color[1] = selected ? .78f : .86f;
    constants.color[2] = 1.f;
    constants.color[3] = selected ? .98f : .74f;
    constants.pick[1] = constants.pick[2] = constants.pick[3] = 0;
    std::fill(std::begin(constants.managed_face),
              std::end(constants.managed_face), 0);
    context_->UpdateSubresource(constants_.Get(), 0, nullptr, &constants, 0,
                                0);
    context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(), 0);
    context_->OMSetBlendState(cad_edge_blend_.Get(), nullptr, UINT_MAX);
    context_->RSSetState(cad_edge_rasterizer_.Get());
    context_->IASetInputLayout(input_layout_.Get());
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);
    context_->IASetVertexBuffers(0, 1, face.boundary_buffer.GetAddressOf(),
                                 &stride, &offset);
    context_->IASetIndexBuffer(nullptr, DXGI_FORMAT_UNKNOWN, 0);
    context_->VSSetShader(vertex_shader_.Get(), nullptr, 0);
    context_->PSSetShader(line_shader_.Get(), nullptr, 0);
    context_->Draw(face.boundary_vertex_count, 0);
  };
  draw_managed_face_boundary(managed_face_selection_, true);
  if (managed_face_hover_.entity_id != managed_face_selection_.entity_id ||
      managed_face_hover_.first_triangle !=
          managed_face_selection_.first_triangle)
    draw_managed_face_boundary(managed_face_hover_, false);
  context_->RSSetState(rasterizer_.Get());
  context_->OMSetBlendState(nullptr, nullptr, UINT_MAX);
  if(hover_.valid()&&hover_.kind>=2){auto found=entities_.find(hover_.entity_id);if(found!=entities_.end()){auto&e=found->second;context_->OMSetDepthStencilState(pick_overlay_depth_state_.Get(),0);context_->IASetInputLayout(pick_input_layout_.Get());context_->IASetIndexBuffer(nullptr,DXGI_FORMAT_UNKNOWN,0);context_->VSSetShader(pick_subentity_vs_.Get(),nullptr,0);context_->PSSetShader(hover_ps_.Get(),nullptr,0);stride=sizeof(PickVertex);constants.pick[1]=hover_.kind;constants.pick[2]=hover_.id;context_->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);
    const int radius=hover_.kind==2?1:3;for(int oy=-radius;oy<=radius;++oy)for(int ox=-radius;ox<=radius;++ox){D3D11_VIEWPORT highlight_vp{static_cast<float>(ox),static_cast<float>(oy),static_cast<float>(width_),static_cast<float>(height_),0,1};context_->RSSetViewports(1,&highlight_vp);if(hover_.kind==2&&e.edge_buffer&&hover_.id*2<=e.edge_vertices.size()){context_->IASetVertexBuffers(0,1,e.edge_buffer.GetAddressOf(),&stride,&offset);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_LINELIST);context_->Draw(2,(hover_.id-1)*2);}else if(hover_.kind==3&&e.point_buffer&&hover_.id<=e.point_vertices.size()){context_->IASetVertexBuffers(0,1,e.point_buffer.GetAddressOf(),&stride,&offset);context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);context_->Draw(1,hover_.id-1);}}context_->RSSetViewports(1,&vp);}}
  context_->Flush();++frames_;const auto now=std::chrono::steady_clock::now();const double elapsed=std::chrono::duration<double>(now-metric_start_).count();if(elapsed>=1){fps_=frames_/elapsed;frames_=0;metric_start_=now;}
  render_ms_=std::chrono::duration<double,std::milli>(now-start).count();
  if(texture_id_>=0){++frame_marks_;if(registrar_->MarkTextureFrameAvailable(texture_id_))++successful_frame_marks_;}
}

void NativeViewportHost::RenderTextureProbe() {
  std::scoped_lock lock(mutex_);
  if (!target_view_) return;
  const Vertex vertices[] = {
      {-0.72f, -0.62f, 0.5f, 0, 0, 1},
      { 0.00f,  0.72f, 0.5f, 0, 0, 1},
      { 0.72f, -0.62f, 0.5f, 0, 0, 1},
  };
  D3D11_BUFFER_DESC description{};
  description.ByteWidth = sizeof(vertices);
  description.Usage = D3D11_USAGE_IMMUTABLE;
  description.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  D3D11_SUBRESOURCE_DATA source{vertices};
  ComPtr<ID3D11Buffer> buffer;
  Check(device_->CreateBuffer(&description, &source, &buffer), "probe VB");
  const float background[]{0.02f, 0.12f, 0.80f, 1};
  context_->ClearRenderTargetView(target_view_.Get(), background);
  context_->ClearDepthStencilView(depth_view_.Get(), D3D11_CLEAR_DEPTH, 1, 0);
  {
    D3D11_TEXTURE2D_DESC clear_description{};
    target_texture_->GetDesc(&clear_description);
    clear_description.Width = 1;
    clear_description.Height = 1;
    clear_description.BindFlags = 0;
    clear_description.MiscFlags = 0;
    clear_description.Usage = D3D11_USAGE_STAGING;
    clear_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> clear_sample;
    Check(device_->CreateTexture2D(&clear_description, nullptr, &clear_sample),
          "probe clear sample");
    D3D11_BOX clear_box{width_ / 2, height_ / 2, 0, width_ / 2 + 1,
                        height_ / 2 + 1, 1};
    context_->CopySubresourceRegion(clear_sample.Get(), 0, 0, 0, 0,
                                    target_texture_.Get(), 0, &clear_box);
    D3D11_MAPPED_SUBRESOURCE clear_mapped{};
    Check(context_->Map(clear_sample.Get(), 0, D3D11_MAP_READ, 0,
                        &clear_mapped), "probe clear map");
    sampled_clear_bgra_ =
        *static_cast<const uint32_t*>(clear_mapped.pData);
    context_->Unmap(clear_sample.Get(), 0);
  }
  context_->OMSetRenderTargets(1, target_view_.GetAddressOf(), depth_view_.Get());
  D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width_),
                         static_cast<float>(height_), 0, 1};
  context_->RSSetViewports(1, &viewport);
  constexpr char probe_shader[] = R"(
    struct In { float3 p : POSITION; };
    struct Out { float4 p : SV_POSITION; };
    Out VSProbe(In input) { Out output; output.p=float4(input.p,1); return output; }
    float4 PSProbe(Out input) : SV_TARGET { return float4(1,0,0,1); }
  )";
  ComPtr<ID3DBlob> probe_vs_blob, probe_ps_blob, probe_errors;
  Check(D3DCompile(probe_shader, sizeof(probe_shader), nullptr, nullptr,
                   nullptr, "VSProbe", "vs_5_0", D3DCOMPILE_ENABLE_STRICTNESS,
                   0, &probe_vs_blob, &probe_errors), "probe VS compile");
  Check(D3DCompile(probe_shader, sizeof(probe_shader), nullptr, nullptr,
                   nullptr, "PSProbe", "ps_5_0", D3DCOMPILE_ENABLE_STRICTNESS,
                   0, &probe_ps_blob, &probe_errors), "probe PS compile");
  ComPtr<ID3D11VertexShader> probe_vs;
  ComPtr<ID3D11PixelShader> probe_ps;
  ComPtr<ID3D11InputLayout> probe_layout;
  Check(device_->CreateVertexShader(probe_vs_blob->GetBufferPointer(),
                                    probe_vs_blob->GetBufferSize(), nullptr,
                                    &probe_vs), "probe VS");
  Check(device_->CreatePixelShader(probe_ps_blob->GetBufferPointer(),
                                   probe_ps_blob->GetBufferSize(), nullptr,
                                   &probe_ps), "probe PS");
  const D3D11_INPUT_ELEMENT_DESC probe_element{
      "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0,
      D3D11_INPUT_PER_VERTEX_DATA, 0};
  Check(device_->CreateInputLayout(&probe_element, 1,
                                   probe_vs_blob->GetBufferPointer(),
                                   probe_vs_blob->GetBufferSize(),
                                   &probe_layout), "probe input layout");
  UINT stride = sizeof(Vertex), offset = 0;
  context_->IASetInputLayout(probe_layout.Get());
  context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context_->IASetVertexBuffers(0, 1, buffer.GetAddressOf(), &stride, &offset);
  context_->VSSetShader(probe_vs.Get(), nullptr, 0);
  context_->PSSetShader(probe_ps.Get(), nullptr, 0);
  context_->RSSetState(rasterizer_.Get());
  context_->OMSetDepthStencilState(depth_state_.Get(), 0);
  context_->Draw(3, 0);
  context_->Flush();

  D3D11_TEXTURE2D_DESC sample_description{};
  target_texture_->GetDesc(&sample_description);
  sample_description.Width = 1;
  sample_description.Height = 1;
  sample_description.BindFlags = 0;
  sample_description.MiscFlags = 0;
  sample_description.Usage = D3D11_USAGE_STAGING;
  sample_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> sample;
  Check(device_->CreateTexture2D(&sample_description, nullptr, &sample),
        "probe sample");
  D3D11_BOX box{width_ / 2, height_ / 2, 0, width_ / 2 + 1,
                height_ / 2 + 1, 1};
  context_->CopySubresourceRegion(sample.Get(), 0, 0, 0, 0,
                                  target_texture_.Get(), 0, &box);
  D3D11_MAPPED_SUBRESOURCE mapped{};
  Check(context_->Map(sample.Get(), 0, D3D11_MAP_READ, 0, &mapped),
        "probe map");
  sampled_bgra_ = *static_cast<const uint32_t*>(mapped.pData);
  context_->Unmap(sample.Get(), 0);
  triangles_ = 1;
  if (texture_id_ >= 0) {
    ++frame_marks_;
    if (registrar_->MarkTextureFrameAvailable(texture_id_))
      ++successful_frame_marks_;
  }
}

NativeViewportHost::PickResult NativeViewportHost::Pick(int x,int y){
  const auto started=std::chrono::steady_clock::now();PickResult best{};
  if(!pick_target_||x<0||y<0||x>=static_cast<int>(width_)||y>=static_cast<int>(height_))return best;
  const float clear[4]{};context_->ClearRenderTargetView(pick_target_.Get(),clear);
  context_->ClearDepthStencilView(depth_view_.Get(),D3D11_CLEAR_DEPTH,1,0);
  context_->OMSetRenderTargets(1,pick_target_.GetAddressOf(),depth_view_.Get());
  D3D11_VIEWPORT viewport{0,0,static_cast<float>(width_),static_cast<float>(height_),0,1};context_->RSSetViewports(1,&viewport);
  const auto frame=camera_.BuildFrame(static_cast<float>(width_)/height_);Constants constants{};
  XMStoreFloat4x4(reinterpret_cast<XMFLOAT4X4*>(constants.matrix),frame.world_view_projection);
  context_->VSSetConstantBuffers(0,1,constants_.GetAddressOf());context_->PSSetConstantBuffers(0,1,constants_.GetAddressOf());
  context_->RSSetState(rasterizer_.Get());context_->OMSetDepthStencilState(depth_state_.Get(),0);
  context_->IASetInputLayout(input_layout_.Get());context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context_->VSSetShader(pick_face_vs_.Get(),nullptr,0);context_->PSSetShader(pick_face_ps_.Get(),nullptr,0);
  UINT stride=sizeof(Vertex),offset=0,entity_code=0;std::vector<SceneEntity*> lookup(1,nullptr);
  for(auto&[id,e]:entities_){if(!e.visible||!e.vertex_buffer||!e.index_buffer)continue;++entity_code;lookup.push_back(&e);constants.pick[0]=entity_code;
    context_->UpdateSubresource(constants_.Get(),0,nullptr,&constants,0,0);context_->IASetVertexBuffers(0,1,e.vertex_buffer.GetAddressOf(),&stride,&offset);context_->IASetIndexBuffer(e.index_buffer.Get(),DXGI_FORMAT_R32_UINT,0);context_->DrawIndexed(static_cast<UINT>(e.indices.size()),0,0);}
  constexpr int tolerance=7;D3D11_BOX sample_box{static_cast<UINT>(std::max(x-tolerance,0)),static_cast<UINT>(std::max(y-tolerance,0)),0,static_cast<UINT>(std::min(x+tolerance+1,static_cast<int>(width_))),static_cast<UINT>(std::min(y+tolerance+1,static_cast<int>(height_))),1};
  context_->CopySubresourceRegion(pick_readback_.Get(),0,sample_box.left,sample_box.top,0,pick_texture_.Get(),0,&sample_box);D3D11_MAPPED_SUBRESOURCE mapped{};Check(context_->Map(pick_readback_.Get(),0,D3D11_MAP_READ,0,&mapped),"map pick buffer");
  int best_priority=0,best_distance=INT_MAX;
  for(int dy=-tolerance;dy<=tolerance;++dy){const int sy=y+dy;if(sy<0||sy>=static_cast<int>(height_))continue;const auto* row=reinterpret_cast<const uint32_t*>(static_cast<const uint8_t*>(mapped.pData)+static_cast<size_t>(sy)*mapped.RowPitch);
    for(int dx=-tolerance;dx<=tolerance;++dx){const int sx=x+dx;if(sx<0||sx>=static_cast<int>(width_))continue;const uint32_t kind=row[sx*4],code=row[sx*4+1],id=row[sx*4+2];if(kind!=1||code==0||code>=lookup.size()||id==0)continue;const int distance=dx*dx+dy*dy;if(best_priority==0||distance<best_distance){best_priority=1;best_distance=distance;best.kind=kind;best.id=id;best.entity_id=lookup[code]->id;}}}
  context_->Unmap(pick_readback_.Get(),0);
  if(best.valid()){SceneEntity* entity=nullptr;for(auto* candidate:lookup)if(candidate&&candidate->id==best.entity_id){entity=candidate;break;}if(!entity)return{};
    if(best.kind==1){const size_t base=(best.id-1)*3;if(base+2<entity->indices.size()){for(int axis=0;axis<3;++axis){const auto coordinate=[&](uint32_t index){const auto&v=entity->vertices[index];return axis==0?v.x:axis==1?v.y:v.z;};best.point[axis]=(coordinate(entity->indices[base])+coordinate(entity->indices[base+1])+coordinate(entity->indices[base+2]))/3;}}}
    else if(best.kind==2){const size_t base=(best.id-1)*2;if(base+1<entity->edge_vertices.size()){best.point[0]=(entity->edge_vertices[base].x+entity->edge_vertices[base+1].x)/2;best.point[1]=(entity->edge_vertices[base].y+entity->edge_vertices[base+1].y)/2;best.point[2]=(entity->edge_vertices[base].z+entity->edge_vertices[base+1].z)/2;}}
    else if(best.kind==3&&best.id<=entity->point_vertices.size()){const auto&p=entity->point_vertices[best.id-1];best.point[0]=p.x;best.point[1]=p.y;best.point[2]=p.z;}}
  picking_ms_=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();return best;
}

flutter::EncodableMap NativeViewportHost::EncodePick(const PickResult& value)const{
  if(!value.valid())return{};return{{flutter::EncodableValue("entityId"),flutter::EncodableValue(value.entity_id)},{flutter::EncodableValue("kind"),flutter::EncodableValue(static_cast<int32_t>(value.kind))},{flutter::EncodableValue("subId"),flutter::EncodableValue(static_cast<int64_t>(value.id))},{flutter::EncodableValue("point"),flutter::EncodableValue(flutter::EncodableList{flutter::EncodableValue(static_cast<double>(value.point[0])),flutter::EncodableValue(static_cast<double>(value.point[1])),flutter::EncodableValue(static_cast<double>(value.point[2]))})}};
}

void NativeViewportHost::Fit(){float mn[3]{INFINITY,INFINITY,INFINITY},mx[3]{-INFINITY,-INFINITY,-INFINITY};for(const auto&[id,e]:entities_)for(const auto&v:e.vertices){mn[0]=std::min(mn[0],v.x);mn[1]=std::min(mn[1],v.y);mn[2]=std::min(mn[2],v.z);mx[0]=std::max(mx[0],v.x);mx[1]=std::max(mx[1],v.y);mx[2]=std::max(mx[2],v.z);}if(!std::isfinite(mn[0]))return;camera_.Fit(mn,mx);++fit_calls_;}
void NativeViewportHost::Orbit(double dx,double dy){std::scoped_lock lock(mutex_);camera_.OrbitRadians(static_cast<float>(dx),static_cast<float>(dy));Render();}
void NativeViewportHost::Pan(double dx,double dy){std::scoped_lock lock(mutex_);camera_.PanPixels(static_cast<float>(dx),static_cast<float>(dy));Render();}
void NativeViewportHost::Zoom(double factor){std::scoped_lock lock(mutex_);camera_.ZoomFactor(static_cast<float>(factor));Render();}
void NativeViewportHost::SetCamera(const flutter::EncodableMap& arguments) {
  std::scoped_lock lock(mutex_);
  if (const auto *value = Find(arguments, "renderStyle")) {
    const auto style = Number(*value);
    if (style < 0 || style > 3 || !std::isfinite(style) || std::floor(style) != style)
      throw std::runtime_error("Invalid render style");
    render_style_ = static_cast<uint32_t>(style);
  }
  ++set_camera_calls_;
  const auto read_vector = [&arguments](const char* key, float output[3]) {
    const auto* raw = Find(arguments, key);
    const auto* values = raw ? std::get_if<flutter::EncodableList>(raw) : nullptr;
    if (!values || values->size() != 3) return false;
    for (size_t i = 0; i < 3; ++i)
      output[i] = static_cast<float>(Number((*values)[i]));
    return true;
  };
  float eye[3], target[3], up[3];
  const auto* fov = Find(arguments, "fov");
  const auto* near_plane = Find(arguments, "near");
  const auto* far_plane = Find(arguments, "far");
  const auto* projection_mode = Find(arguments, "projectionMode");
  const auto* orthographic_height = Find(arguments, "orthographicHeight");
  const auto* pan_offset_x = Find(arguments, "panOffsetX");
  const auto* pan_offset_y = Find(arguments, "panOffsetY");
  if (!read_vector("eye", eye) || !read_vector("target", target) ||
      !read_vector("up", up) || !fov || !near_plane || !far_plane) return;
  const float fov_value = static_cast<float>(Number(*fov));
  const float near_value = static_cast<float>(Number(*near_plane));
  const float far_value = static_cast<float>(Number(*far_plane));
  if (!std::isfinite(fov_value) || !std::isfinite(near_value) ||
      !std::isfinite(far_value) || fov_value <= 0 ||
      fov_value >= XM_PI || near_value <= 0 || far_value <= near_value) return;
  camera_.SetPose(eye, target, up);
  camera_.SetLens(fov_value, near_value, far_value);
  const auto* projection_name = projection_mode
      ? std::get_if<std::string>(projection_mode)
      : nullptr;
  camera_.SetProjection(
      projection_name && *projection_name == "orthographic",
      orthographic_height
          ? static_cast<float>(Number(*orthographic_height))
          : 10.0f);
  if (pan_offset_x && pan_offset_y) {
    camera_.SetProjectionOffset(
        static_cast<float>(Number(*pan_offset_x)),
        static_cast<float>(Number(*pan_offset_y)));
  }
  Render();
}
void NativeViewportHost::RemoveEntity(const std::string&id){std::scoped_lock lock(mutex_);entities_.erase(id);if(managed_face_hover_.entity_id==id)managed_face_hover_={};if(managed_face_selection_.entity_id==id)managed_face_selection_={};Render();}
flutter::EncodableMap NativeViewportHost::Stats()const{std::string gpu;gpu.reserve(adapter_name_.size());for(const wchar_t character:adapter_name_)gpu.push_back(character<=0x7f?static_cast<char>(character):'?');return{{flutter::EncodableValue("fps"),flutter::EncodableValue(fps_)},{flutter::EncodableValue("drawCalls"),flutter::EncodableValue(static_cast<int64_t>(entities_.size()))},{flutter::EncodableValue("triangles"),flutter::EncodableValue(static_cast<int64_t>(triangles_))},{flutter::EncodableValue("uploadMs"),flutter::EncodableValue(upload_ms_)},{flutter::EncodableValue("renderMs"),flutter::EncodableValue(render_ms_)},{flutter::EncodableValue("pickingMs"),flutter::EncodableValue(picking_ms_)},{flutter::EncodableValue("gpu"),flutter::EncodableValue(gpu)},{flutter::EncodableValue("setCameraCalls"),flutter::EncodableValue(static_cast<int64_t>(set_camera_calls_))},{flutter::EncodableValue("renderCalls"),flutter::EncodableValue(static_cast<int64_t>(render_calls_))},{flutter::EncodableValue("constantBufferUpdates"),flutter::EncodableValue(static_cast<int64_t>(constant_buffer_updates_))},{flutter::EncodableValue("drawIndexedCalls"),flutter::EncodableValue(static_cast<int64_t>(draw_indexed_calls_))},{flutter::EncodableValue("fitCalls"),flutter::EncodableValue(static_cast<int64_t>(fit_calls_))},{flutter::EncodableValue("cameraDistance"),flutter::EncodableValue(static_cast<double>(camera_.Distance()))},{flutter::EncodableValue("cameraRadius"),flutter::EncodableValue(static_cast<double>(camera_.Radius()))},{flutter::EncodableValue("cameraNear"),flutter::EncodableValue(static_cast<double>(camera_.NearPlane()))},{flutter::EncodableValue("cameraFar"),flutter::EncodableValue(static_cast<double>(camera_.FarPlane()))},{flutter::EncodableValue("textureId"),flutter::EncodableValue(texture_id_)},{flutter::EncodableValue("textureRegistered"),flutter::EncodableValue(texture_registered_)},{flutter::EncodableValue("textureCallbacks"),flutter::EncodableValue(static_cast<int64_t>(texture_callbacks_.load()))},{flutter::EncodableValue("textureCallbackHz"),flutter::EncodableValue(texture_callback_hz_)},{flutter::EncodableValue("frameMarks"),flutter::EncodableValue(static_cast<int64_t>(frame_marks_.load()))},{flutter::EncodableValue("successfulFrameMarks"),flutter::EncodableValue(static_cast<int64_t>(successful_frame_marks_.load()))},{flutter::EncodableValue("requestedWidth"),flutter::EncodableValue(static_cast<int64_t>(last_requested_width_))},{flutter::EncodableValue("requestedHeight"),flutter::EncodableValue(static_cast<int64_t>(last_requested_height_))},{flutter::EncodableValue("sampledBgra"),flutter::EncodableValue(static_cast<int64_t>(sampled_bgra_))},{flutter::EncodableValue("sampledClearBgra"),flutter::EncodableValue(static_cast<int64_t>(sampled_clear_bgra_))},{flutter::EncodableValue("silhouetteAcceptedSegments"),flutter::EncodableValue(static_cast<int64_t>(silhouette_accepted_segments_))},{flutter::EncodableValue("silhouetteRejectedSegments"),flutter::EncodableValue(static_cast<int64_t>(silhouette_rejected_segments_))},{flutter::EncodableValue("silhouetteDrawnSegments"),flutter::EncodableValue(static_cast<int64_t>(silhouette_drawn_segments_))},{flutter::EncodableValue("meshDerivedDrawnSegments"),flutter::EncodableValue(static_cast<int64_t>(mesh_derived_drawn_segments_))},{flutter::EncodableValue("displayEdgesDrawnSegments"),flutter::EncodableValue(static_cast<int64_t>(display_edges_drawn_segments_))},{flutter::EncodableValue("presentationBuffer"),flutter::EncodableValue(presentation_buffer_)}};}
const FlutterDesktopGpuSurfaceDescriptor *
NativeViewportHost::SurfaceState::Describe(size_t width, size_t height) {
  std::scoped_lock lock(mutex);
  if (!texture)
    return nullptr;
  if (on_callback)
    on_callback(width, height);
  descriptor.release_context = texture.Get();
  texture->AddRef();
  return &descriptor;
}
const FlutterDesktopGpuSurfaceDescriptor *
NativeViewportHost::SurfaceDescriptor(size_t width, size_t height) {
  return surface_state_ ? surface_state_->Describe(width, height) : nullptr;
}
void NativeViewportHost::Shutdown(std::function<void()> completed) {
  std::unique_lock lock(mutex_);
  const auto retiring_id = texture_id_;
  auto retiring_texture =
      std::shared_ptr<flutter::TextureVariant>(std::move(flutter_texture_));
  texture_id_ = -1;
  texture_registered_ = false;
  if (surface_state_) {
    std::scoped_lock surface_lock(surface_state_->mutex);
    surface_state_->on_callback = {};
    surface_state_->texture.Reset();
  }
  surface_state_.reset();
  if (context_) {
    context_->ClearState();
    context_->Flush();
  }
  entities_.clear();
  operational_hover_index_buffer_.Reset();
  operational_selection_index_buffer_.Reset();
  operational_hover_index_count_ = operational_selection_index_count_ = 0;
  operational_hover_entity_id_.clear();
  operational_hover_id_.clear();
  operational_selection_entity_id_.clear();
  operational_selection_id_.clear();
  hover_ = {};
  managed_face_hover_ = {};
  managed_face_selection_ = {};
  target_view_.Reset();
  target_texture_.Reset();
  shared_texture_handle_ = nullptr;
  depth_view_.Reset();
  depth_texture_.Reset();
  pick_target_.Reset();
  pick_readback_.Reset();
  pick_texture_.Reset();
  vertex_shader_.Reset();
  pixel_shader_.Reset();
  line_shader_.Reset();
  pick_face_vs_.Reset();
  pick_subentity_vs_.Reset();
  pick_face_ps_.Reset();
  pick_edge_ps_.Reset();
  pick_vertex_ps_.Reset();
  hover_ps_.Reset();
  input_layout_.Reset();
  pick_input_layout_.Reset();
  constants_.Reset();
  rasterizer_.Reset();
  edge_rasterizer_.Reset();
  cad_edge_rasterizer_.Reset();
  cad_edge_blend_.Reset();
  depth_state_.Reset();
  pick_overlay_depth_state_.Reset();
  context_.Reset();
  device_.Reset();
  triangles_ = 0;
  scene_revision_ = 0;
  lock.unlock();
  if (retiring_id >= 0 && registrar_) {
    registrar_->UnregisterTexture(retiring_id, [retiring_texture, completed] {
      if (completed)
        completed();
    });
  } else if (completed) {
    completed();
  }
}
