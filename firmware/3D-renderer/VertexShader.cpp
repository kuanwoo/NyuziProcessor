// 
// Copyright 2013 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 

#include "Debug.h"
#include "VertexShader.h"
#include "Core.h"

using namespace render;

const veci16 kStepVector = { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60 };

VertexShader::VertexShader(int attribsPerVertex, int paramsPerVertex)
	:	fParamsPerVertex(paramsPerVertex),
		fParamStepVector(kStepVector * splati(paramsPerVertex)),
		fAttribsPerVertex(attribsPerVertex),
		fAttribStepVector(kStepVector * splati(attribsPerVertex))
{
}

void VertexShader::processVertices(float *outParams, const float *attribs, int numVertices)
{
	int mask;
	if (numVertices < 16)
		mask = (0xffff0000 >> numVertices) & 0xffff;
	else
		mask = 0xffff;

	// Gather from attribute buffer int packedAttribs buffer
	veci16 attribPtr = fAttribStepVector + splati((unsigned int) attribs);
	vecf16 packedAttribs[fAttribsPerVertex];
	for (int attrib = 0; attrib < fAttribsPerVertex; attrib++)
	{
		packedAttribs[attrib] = __builtin_vp_gather_loadf_masked(attribPtr, mask); 
		attribPtr += splati(4);
	}

	vecf16 packedParams[fParamsPerVertex];
	shadeVertices(packedParams, packedAttribs, mask);

	// Perform perspective division
	vecf16 oneOverW = splatf(1.0) / packedParams[kParamW];
	packedParams[kParamX] *= oneOverW;
	packedParams[kParamY] *= oneOverW;

	veci16 paramPtr = fParamStepVector + splati((unsigned int) outParams);

	// Scatter packedParams back out to parameter buffer
	for (int param = 0; param < fParamsPerVertex; param++)
	{
		__builtin_vp_scatter_storef_masked(paramPtr, packedParams[param], mask);
		paramPtr += splati(4);
	}
}

