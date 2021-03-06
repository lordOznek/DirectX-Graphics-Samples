//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************
#define END_SEARCH -1
#define IGNORE      0
#define ACCEPT      1

groupshared
uint    stack[TRAVERSAL_MAX_STACK_DEPTH * WAVE_SIZE];

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
RWTexture2D<float4> g_screenOutput : register(u2);
void VisualizeAcceleratonStructure(float closestBoxT)
{
    g_screenOutput[DispatchRaysIndex()] = float4(closestBoxT / 3000.0f, 0, 0, 1);
}

groupshared
uint    depthStack[TRAVERSAL_MAX_STACK_DEPTH * WAVE_SIZE];
#endif

void RecordClosestBox(uint currentLevel, inout bool leftTest, float leftT, inout bool rightTest, float rightT, inout float closestBoxT)
{
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    if (Debug.LevelToVisualize == currentLevel)
    {
        if (rightTest)
        {
            closestBoxT = min(closestBoxT, rightT);
            rightTest = false;
        }

        if (leftTest)
        {
            closestBoxT = min(closestBoxT, leftT);
            leftTest = false;
        }
    }
#endif
}

void StackPush(inout int stackTop, uint value, uint level, uint tidInWave)
{
    uint stackIndex = tidInWave + (stackTop * WAVE_SIZE);
    stack[stackIndex] = value;
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    depthStack[stackIndex] = level;
#endif
    stackTop++;
}

void StackPush2(inout int stackTop, bool selector, uint valueA, uint valueB, uint level, uint tidInWave)
{
    const uint store0 = selector ? valueA : valueB;
    const uint store1 = selector ? valueB : valueA;
    const uint stackIndex0 = tidInWave + (stackTop + 0) * WAVE_SIZE;
    const uint stackIndex1 = tidInWave + (stackTop + 1) * WAVE_SIZE;
    stack[stackIndex0] = store0;
    stack[stackIndex1] = store1;

#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    depthStack[stackIndex0] = level;
    depthStack[stackIndex1] = level;
#endif

    stackTop += 2;
}

uint StackPop(inout int stackTop, out uint depth, uint tidInWave)
{
    --stackTop;
    uint stackIndex = tidInWave + (stackTop * WAVE_SIZE);
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    depth = depthStack[stackIndex];
#endif
    return stack[stackIndex];
}

void Fallback_IgnoreHit()
{
    Fallback_SetAnyHitResult(IGNORE);
}

void Fallback_AcceptHitAndEndSearch()
{
    Fallback_SetAnyHitResult(END_SEARCH);
}

//
// Ray/AABB intersection, separating axes theorem
//

inline
bool RayBoxTest(
    out float resultT,
    float closestT,
    float3 rayOriginTimesRayInverseDirection,
    float3 rayInverseDirection,
    float3 boxCenter,
    float3 boxHalfDim)
{
    const float3 relativeMiddle = boxCenter * rayInverseDirection - rayOriginTimesRayInverseDirection; // 3
    const float3 maxL = relativeMiddle + boxHalfDim * abs(rayInverseDirection); // 3
    const float3 minL = relativeMiddle - boxHalfDim * abs(rayInverseDirection); // 3

    const float minT = max(max(minL.x, minL.y), minL.z); // 1
    const float maxT = min(min(maxL.x, maxL.y), maxL.z); // 1

    resultT = max(minT, 0);
    return max(minT, 0) < min(maxT, closestT);
}

float3 Swizzle(float3 v, int3 swizzleOrder)
{
    return float3(v[swizzleOrder.x], v[swizzleOrder.y], v[swizzleOrder.z]);
}

// Using Woop/Benthin/Wald 2013: "Watertight Ray/Triangle Intersection"
inline
void RayTriangleIntersect(
    inout float hitT,
    in uint instanceFlags,
    out float2 bary,
    float3 rayOrigin,
    float3 rayDirection,
    int3 swizzledIndicies,
    float3 shear,
    float3 v0,
    float3 v1,
    float3 v2)
{
    // Woop Triangle Intersection
    bool useCulling = !(instanceFlags & D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_CULL_DISABLE);
    bool flipFaces = instanceFlags & D3D12_RAYTRACING_INSTANCE_FLAG_TRIANGLE_FRONT_COUNTERCLOCKWISE;
    uint backFaceCullingFlag = flipFaces ? RAY_FLAG_CULL_FRONT_FACING_TRIANGLES : RAY_FLAG_CULL_BACK_FACING_TRIANGLES;
    uint frontFaceCullingFlag = flipFaces ? RAY_FLAG_CULL_BACK_FACING_TRIANGLES : RAY_FLAG_CULL_FRONT_FACING_TRIANGLES;
    bool useBackfaceCulling = useCulling && (RayFlags() & backFaceCullingFlag);
    bool useFrontfaceCulling = useCulling && (RayFlags() & frontFaceCullingFlag);

    float3 A = Swizzle(v0 - rayOrigin, swizzledIndicies);
    float3 B = Swizzle(v1 - rayOrigin, swizzledIndicies);
    float3 C = Swizzle(v2 - rayOrigin, swizzledIndicies);

    A.xy = A.xy - shear * A.z;
    B.xy = B.xy - shear * B.z;
    C.xy = C.xy - shear * C.z;
    precise float U = C.x * B.y - C.y * B.x;
    precise float V = A.x * C.y - A.y * C.x;
    precise float W = B.x * A.y - B.y * A.x;
        
    float det = U + V + W;
    if (useFrontfaceCulling)
    {
        if (U>0.0f || V>0.0f || W>0.0f) return;
    }
    else if(useBackfaceCulling)
    {
        if (U<0.0f || V<0.0f || W<0.0f) return;
    }
    else
    {
        if ((U<0.0f || V<0.0f || W<0.0f) &&
            (U>0.0f || V>0.0f || W>0.0f)) return;
    }

    if (det == 0.0f) return;
    A.z = shear.z * A.z;
    B.z = shear.z * B.z;
    C.z = shear.z * C.z;
    const float T = U * A.z + V * B.z + W * C.z;
    if (useFrontfaceCulling)
    {
        if (T > 0.0f || T < hitT * det)
            return;
    }
    else if (useBackfaceCulling)
    {
        if (T < 0.0f || T > hitT * det)
            return;
    }
    else
    {
        int det_sign = det > 0.0 ? 1 : -1;
        if (((asuint(T) ^ det_sign) < 0.0f) ||
            (asuint(T) ^ det_sign) > hitT * (asuint(det) ^ det_sign))
            return;
    }
    const float rcpDet = rcp(det);
    bary.x = V * rcpDet;
    bary.y = W * rcpDet;
    hitT = T * rcpDet;
}

#define MULTIPLE_LEAVES_PER_NODE 0
bool TestLeafNodeIntersections(
    RWByteAddressBufferPointer accelStruct,
    uint2 flags,
    uint instanceFlags,
    float3 rayOrigin,
    float3 rayDirection,
    int3 swizzledIndicies,
    float3 shear,
    inout float2 resultBary,
    inout float resultT,
    inout uint resultTriId)
{
    // Intersect a bunch of triangles
    const uint firstId = flags.x & 0x00ffffff;
    const uint numTris = flags.y;

    // Unroll mildly, it'd be awesome if we had some helpers here to intersect.
    uint i = 0;
    bool bIsIntersect = false;
#if MULTIPLE_LEAVES_PER_NODE
    const uint evenTris = numTris & ~1;
    for (i = 0; i < evenTris; i += 2)
    {
        const uint id0 = firstId + i;

        const uint2 triIds = uint2(id0, id0 + 1);

        // Read 3 vertices
        // This is pumping too much via SQC
        float3 v00, v01, v02;
        float3 v10, v11, v12;
        BVHReadTriangle(accelStruct, v00, v01, v02, triIds.x);
        BVHReadTriangle(accelStruct, v10, v11, v12, triIds.y);

        // Intersect
        float2 bary0, bary1;
        float t0 = resultT;
        RayTriangleIntersect(
            t0,
            instanceFlags,
            bary0,
            rayOrigin,
            rayDirection,
            swizzledIndicies,
            shear,
            v00, v01, v02);
        
        float t1 = resultT;
        RayTriangleIntersect(
            t1,
            instanceFlags,
            bary1,
            rayOrigin,
            rayDirection,
            swizzledIndicies,
            shear,
            v10, v11, v12);

        // Record nearest
        if (t0 < resultT)
        {
            resultBary = bary0.xy;
            resultT = t0;
            resultTriId = triIds.x;
            bIsIntersect = true;
        }

        if (t1 < resultT)
        {
            resultBary = bary1.xy;
            resultT = t1;
            resultTriId = triIds.y;
            bIsIntersect = true;
        }
    }

    if (numTris & 1)
#endif
    {
        const uint triId0 = firstId + i;

        // Read 3 vertices
        float3 v0, v1, v2;
        BVHReadTriangle(accelStruct, v0, v1, v2, triId0);

        // Intersect
        float2  bary0;
        float t0 = resultT;
        RayTriangleIntersect(
            t0, 
            instanceFlags,
            bary0, 
            rayOrigin, 
            rayDirection, 
            swizzledIndicies,
            shear,
            v0, v1, v2);

        // Record nearest
        if (t0 < resultT && t0 > RayTMin())
        {
            resultBary = bary0.xy;
            resultT = t0;
            resultTriId = triId0;
            bIsIntersect = true;
        }
    }
    return bIsIntersect;
}

int GetIndexOfBiggestChannel(float3 vec)
{
    if (vec.x > vec.y && vec.x > vec.z)
    {
        return 0;
    }
    else if (vec.y > vec.z)
    {
        return 1;
    }
    else
    {
        return 2;
    }
}

void swap(inout int a, inout int b)
{
    int temp = a;
    a = b;
    b = temp;
}

#define TOP_LEVEL_INDEX 0
#define BOTTOM_LEVEL_INDEX 1
#define NUM_BVH_LEVELS 2

struct HitData
{
    uint ContributionToHitGroupIndex;
    uint PrimitiveIndex;
};

struct RayData
{
    float3 Origin;
    float3 Direction;
    
    // Precalculated Stuff for intersection tests
    float3 InverseDirection;
    float3 OriginTimesRayInverseDirection;
    float3 Shear;
    int3   SwizzledIndices;
};

RayData GetRayData(float3 rayOrigin, float3 rayDirection)
{
    RayData data;
    data.Origin = rayOrigin;
    data.Direction = rayDirection;

    // Precompute stuff
    data.InverseDirection = rcp(rayDirection);
    data.OriginTimesRayInverseDirection = rayOrigin * data.InverseDirection;

    int zIndex = GetIndexOfBiggestChannel(abs(rayDirection));
    data.SwizzledIndices = int3(
        (zIndex + 1) % 3,
        (zIndex + 2) % 3,
        zIndex);

    if (rayDirection[data.SwizzledIndices.z] < 0.0f) swap(data.SwizzledIndices.x, data.SwizzledIndices.y);

    data.Shear = float3(
        rayDirection[data.SwizzledIndices.x] / rayDirection[data.SwizzledIndices.z],
        rayDirection[data.SwizzledIndices.y] / rayDirection[data.SwizzledIndices.z],
        1.0 / rayDirection[data.SwizzledIndices.z]);

    return data;
}

bool IsOpaque( bool geomOpaque, uint instanceFlags, uint rayFlags )
{
  bool opaque = geomOpaque;

  if( instanceFlags & INSTANCE_FLAG_FORCE_OPAQUE )
    opaque = true;
  else if( instanceFlags & INSTANCE_FLAG_FORCE_NON_OPAQUE ) 
    opaque = false;

  if( rayFlags & RAY_FLAG_FORCE_OPAQUE )
    opaque = true;
  else if( rayFlags & RAY_FLAG_FORCE_NON_OPAQUE )
    opaque = false;

  return opaque;
}

bool Cull(bool opaque, uint rayFlags)
{
  return (opaque && (rayFlags & RAY_FLAG_CULL_OPAQUE)) || (!opaque && (rayFlags & RAY_FLAG_CULL_NON_OPAQUE));
}

float ComputeCullFaceDir(uint instanceFlags, uint rayFlags)
{
  float cullFaceDir = 0;
  if( rayFlags & RAY_FLAG_CULL_FRONT_FACING_TRIANGLES )
    cullFaceDir = 1;
  else if( rayFlags & RAY_FLAG_CULL_BACK_FACING_TRIANGLES )
    cullFaceDir = -1;
  if( instanceFlags & INSTANCE_FLAG_TRIANGLE_CULL_DISABLE )
    cullFaceDir = 0;

  return cullFaceDir;
}

int InvokeAnyHit(int stateId)
{
  Fallback_SetAnyHitResult(ACCEPT);
  Fallback_CallIndirect(stateId);
  return Fallback_AnyHitResult();
}

//
// Explicit phases. This reconverges after reaching leaves. It makes for a more level performance.
//

#if 1
#define MARK(x,y) LogInt(x*100+10+y)

void dump(BoundingBox box, uint2 flags)
{
  LogFloat3(box.center);
  LogFloat3(box.halfDim);
  LogInt2(flags);
}
#else
#define MARK(x,y) 
void dump(BoundingBox box, uint2 flags) {}
#endif


Declare_Fallback_SetPendingAttr(BuiltInTriangleIntersectionAttributes);
float RayTCurrent();

bool Traverse(
    uint InstanceInclusionMask,
    uint RayContributionToHitGroupIndex,
    uint MultiplierForGeometryContributionToHitGroupIndex
)
{
    uint GI = Fallback_GroupIndex();
    const GpuVA nullptr = GpuVA(0, 0);

    RayData worldRayData = GetRayData(WorldRayOrigin(), WorldRayDirection());
    RayData currentRayData = worldRayData;

    float3x4 CurrentObjectToWorld = 0;
    float3x4 CurrentWorldToObject = 0;
    bool ResetMatrices = true;

    uint nodesToProcess[NUM_BVH_LEVELS];
    uint currentBVHIndex = TOP_LEVEL_INDEX;
    GpuVA currentGpuVA = TopLevelAccelerationStructureGpuVA;
    uint instIdx = 0;
    uint instFlags = 0;
    uint instOffset = 0;
    uint instId = 0;

    uint stackPointer = 0;
    nodesToProcess[TOP_LEVEL_INDEX] = 0;

    RWByteAddressBufferPointer topLevelAccelerationStructure = CreateRWByteAddressBufferPointerFromGpuVA(TopLevelAccelerationStructureGpuVA);
    uint offsetToInstanceDescs = GetOffsetToInstanceDesc(topLevelAccelerationStructure);

    RWByteAddressBufferPointer currentBVH = CreateRWByteAddressBufferPointerFromGpuVA(currentGpuVA);
    uint2 flags;
    float unusedT;
    BoundingBox topLevelBox = BVHReadBoundingBox(
        currentBVH,
        0,
        flags);

    if (RayBoxTest(unusedT,
        RayTCurrent(),
        currentRayData.OriginTimesRayInverseDirection,
        currentRayData.InverseDirection,
        topLevelBox.center,
        topLevelBox.halfDim))
    {
        StackPush(stackPointer, 0, 0, GI);
        nodesToProcess[TOP_LEVEL_INDEX]++;
    }

    float closestBoxT = FLT_MAX;
    int NO_HIT_SENTINEL = ~0;
    Fallback_SetInstanceIndex(NO_HIT_SENTINEL);


    MARK(1, 0);
    while (nodesToProcess[TOP_LEVEL_INDEX] != 0)
    {
        MARK(2, 0);
        do
        {
            MARK(3, 0);
            uint currentLevel;
            uint thisNodeIndex = StackPop(stackPointer, currentLevel, GI);
            nodesToProcess[currentBVHIndex]--;

            RWByteAddressBufferPointer currentBVH = CreateRWByteAddressBufferPointerFromGpuVA(currentGpuVA);

            uint2 flags;
            BoundingBox box = BVHReadBoundingBox(
                currentBVH,
                thisNodeIndex,
                flags);

            {
                MARK(4, 0);
                // Leaf flag tells us whether to read the right index
                if (IsLeaf(flags))
                {
                    MARK(5, 0);
                    if (currentBVHIndex == TOP_LEVEL_INDEX)
                    {
                        MARK(6, 0);
                        instIdx = GetLeafIndexFromFlag(flags);
                        BVHMetadata metadata = GetBVHMetadataFromLeafIndex(
                            topLevelAccelerationStructure,
                            offsetToInstanceDescs,
                            instIdx);
                        RaytracingInstanceDesc instanceDesc = metadata.instanceDesc;
                        instOffset = GetInstanceContributionToHitGroupIndex(instanceDesc);
                        instId = GetInstanceID(instanceDesc);

                        bool validInstance = GetInstanceMask(instanceDesc) & InstanceInclusionMask;
                        if (validInstance)
                        {
                            MARK(7, 0);
                            currentBVHIndex = BOTTOM_LEVEL_INDEX;
                            StackPush(stackPointer, 0, currentLevel + 1, GI);
                            currentGpuVA = instanceDesc.AccelerationStructure;
                            instFlags = GetInstanceFlags(instanceDesc);

                            CurrentWorldToObject = CreateMatrix(instanceDesc.Transform);
                            CurrentObjectToWorld = CreateMatrix(metadata.ObjectToWorld);

                            currentRayData = GetRayData(
                                mul(CurrentWorldToObject, float4(WorldRayOrigin(), 1)),
                                mul(CurrentWorldToObject, float4(WorldRayDirection(), 0)));

                            nodesToProcess[BOTTOM_LEVEL_INDEX] = 1;
                        }
                    }
                    else // if (currentBVHIndex == BOTTOM_LEVEL_INDEX)
                    {
                        MARK(8, 0);
                        bool geomOpaque = true; // TODO: This should be looked up with the triangle data.
                        bool opaque = IsOpaque(geomOpaque, instFlags, RayFlags());
#ifdef DISABLE_ANYHIT 
                        opaque = true;
#endif
                        bool culled = Cull(opaque, RayFlags());
                        float resultT = RayTCurrent();
                        float2 resultBary;
                        uint resultTriId;
                        if (!culled && TestLeafNodeIntersections( // TODO: We need to break out this function so we can run anyhit on each triangle
                            currentBVH,
                            flags,
                            instFlags,
                            currentRayData.Origin,
                            currentRayData.Direction,
                            currentRayData.SwizzledIndices,
                            currentRayData.Shear,
                            resultBary,
                            resultT,
                            resultTriId))
                        {
                            RWByteAddressBufferPointer bottomLevelAccelerationStructure = CreateRWByteAddressBufferPointerFromGpuVA(currentGpuVA);
                            TriangleMetaData triMetadata = BVHReadTriangleMetadata(bottomLevelAccelerationStructure, resultTriId);
                            uint contributionToHitGroupIndex =
                                RayContributionToHitGroupIndex +
                                triMetadata.GeometryContributionToHitGroupIndex * MultiplierForGeometryContributionToHitGroupIndex +
                                instOffset;
                            uint primIdx = triMetadata.PrimitiveIndex;
                            uint hitKind = HIT_KIND_TRIANGLE_FRONT_FACE;

                            BuiltInTriangleIntersectionAttributes attr;
                            attr.barycentrics = resultBary;
                            Fallback_SetPendingAttr(attr);
#if !ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
                            Fallback_SetPendingTriVals(resultT, primIdx, contributionToHitGroupIndex, instIdx, instId, hitKind);
#endif
                            closestBoxT = min(closestBoxT, resultT);

                            if (ResetMatrices)
                            {
                                Fallback_SetObjectRayOrigin(currentRayData.Origin);
                                Fallback_SetObjectRayDirection(currentRayData.Direction);
                                Fallback_SetWorldToObject(CurrentWorldToObject);
                                Fallback_SetObjectToWorld(CurrentObjectToWorld);
                                ResetMatrices = false;
                            }

                            bool endSearch = false;
                            if (opaque)
                            {
                                MARK(8, 1);
                                Fallback_CommitHit();
                                endSearch = RayFlags() & RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
                            }
                            else
                            {
                                MARK(8, 2);
                                uint anyhitStateID = HitGroupShaderTable.Load(contributionToHitGroupIndex * HitGroupShaderRecordStride + 4); // can we just premultiply by the stride when setting the pending values?
                                int ret = ACCEPT;
                                if (anyhitStateID)
                                    ret = InvokeAnyHit(anyhitStateID);
                                if (ret != IGNORE)
                                    Fallback_CommitHit();
                                endSearch = (ret == END_SEARCH) || (RayFlags() & RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH);
                            }

                            if (endSearch)
                            {
                                nodesToProcess[BOTTOM_LEVEL_INDEX] = 0;
                                nodesToProcess[TOP_LEVEL_INDEX] = 0;
                            }
                        }
                    }
                }
                else
                {
                    MARK(9, 0);
                    const uint leftChildIndex = GetLeftNodeIndex(flags);
                    const uint rightChildIndex = GetRightNodeIndex(flags);

                    float resultT = RayTCurrent();
                    uint2 flags;
                    float leftT, rightT;
                    BoundingBox leftBox = BVHReadBoundingBox(
                        currentBVH,
                        leftChildIndex,
                        flags);

                    BoundingBox rightBox = BVHReadBoundingBox(
                        currentBVH,
                        rightChildIndex,
                        flags);

                    bool leftTest = RayBoxTest(
                        leftT,
                        resultT,
                        currentRayData.OriginTimesRayInverseDirection,
                        currentRayData.InverseDirection,
                        leftBox.center,
                        leftBox.halfDim);

                    bool rightTest = RayBoxTest(
                        rightT,
                        resultT,
                        currentRayData.OriginTimesRayInverseDirection,
                        currentRayData.InverseDirection,
                        rightBox.center,
                        rightBox.halfDim);

                    RecordClosestBox(currentLevel, leftTest, leftT, rightTest, rightT, closestBoxT);
                    if (leftTest && rightTest)
                    {
                        // If equal, traverse the left side first since it's encoded to have less triangles
                        bool traverseRightSideFirst = rightT < leftT;
                        StackPush2(stackPointer, traverseRightSideFirst, leftChildIndex, rightChildIndex, currentLevel + 1, GI);
                        nodesToProcess[currentBVHIndex] += 2;
                    }
                    else if (leftTest || rightTest)
                    {
                        StackPush(stackPointer, rightTest ? rightChildIndex : leftChildIndex, currentLevel + 1, GI);
                        nodesToProcess[currentBVHIndex] += 1;
                    }
                }
            }
        } while (nodesToProcess[currentBVHIndex] != 0);
        currentBVHIndex--;
        currentRayData = worldRayData;
        currentGpuVA = TopLevelAccelerationStructureGpuVA;
        ResetMatrices = true;
    } 
    MARK(10,0);
    bool isHit = InstanceIndex() != NO_HIT_SENTINEL;
    if (isHit)
    {
        closestBoxT = RayTCurrent();
    }
#if ENABLE_ACCELERATION_STRUCTURE_VISUALIZATION
    VisualizeAcceleratonStructure(closestBoxT);
#endif
    return isHit;
}
