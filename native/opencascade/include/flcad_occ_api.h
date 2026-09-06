#pragma once
#include <stddef.h>

#if defined(_WIN32)
#define FLCAD_OCC_EXPORT __declspec(dllexport)
#else
#define FLCAD_OCC_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {
FLCAD_OCC_EXPORT int flcad_occ_initialize(char* error, size_t error_size);
FLCAD_OCC_EXPORT void flcad_occ_shutdown();
FLCAD_OCC_EXPORT const char* flcad_occ_version();
FLCAD_OCC_EXPORT const char* flcad_occ_capabilities();
FLCAD_OCC_EXPORT const char* flcad_occ_diagnostics();
FLCAD_OCC_EXPORT int flcad_occ_create_vertex(double x,double y,double z,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_destroy_shape(const char* token,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_edge(const char* start,const char* end,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_wire(const char* edge_tokens,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_face(const char* wire_token,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_shell(const char* face_tokens,double tolerance,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_solid(const char* shell_token,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_extrude(const char* source_token,const double* direction,int solid_output,double draft_angle_degrees,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_plane(const double* origin,const double* normal,double lower,double upper,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_planar_face(const double* points,size_t point_count,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_cylinder(const double* origin,const double* direction,double radius,double lower,double upper,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_cone(const double* apex,const double* direction,double angle,double lower,double upper,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_sphere(const double* center,double radius,double lower,double upper,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_create_torus(const double* center,const double* direction,double major_radius,double minor_radius,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_import_shape(const char* path,const char* format,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* type,size_t type_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_transform_shape(const char* source_token,const double* matrix,int copy_geometry,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* type,size_t type_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_import_stl(const char* path,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,int* vertices,int* triangles,int* degenerate_triangles,double* bounds,int* has_normals,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_destroy_mesh(const char* token,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_mesh_geometry(const char* token,double* nodes,size_t node_values,int* triangles,size_t triangle_values,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_surface_topology(const char* token,char* topology,size_t topology_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_intersect_surfaces(const char* first,const char* second,char* result,size_t result_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_surface_quality(const char* token,const double* draft_direction,int samples,char* result,size_t result_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_surface_operation(const char* operation,const char* source_token,const char* reference_tokens,const double* values,size_t value_count,char* token,size_t token_size,char* fingerprint,size_t fingerprint_size,char* type,size_t type_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_export_shape(const char* token,const char* path,const char* format,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_validate(const char* token,char* diagnostics,size_t diagnostics_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_healing_proposals(const char* token,char* proposals,size_t proposals_size,char* error,size_t error_size);
FLCAD_OCC_EXPORT int flcad_occ_mesh(const char* token,const char* path,double deflection,int* vertices,int* triangles,char* error,size_t error_size);
FLCAD_OCC_EXPORT size_t flcad_occ_shape_count();
}
