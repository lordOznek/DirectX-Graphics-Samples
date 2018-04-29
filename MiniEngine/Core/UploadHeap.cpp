#include "pch.h"
#include "UploadHeap.h"
#include "GraphicsCore.h"
#include "CommandListManager.h"

UploadHeap::UploadHeap(size_t bufferSize)
{
	m_uploadBuffer.init(bufferSize);
}

UploadHeap::~UploadHeap()
{
}

void RingBuffer::init(size_t size)
{
	CD3DX12_HEAP_DESC heapDesc(size, D3D12_HEAP_TYPE_UPLOAD, 64 * 1024, D3D12_HEAP_FLAG_NONE);
	Graphics::g_Device->CreateHeap(&heapDesc, __uuidof(ID3D12Heap), (void**)&m_uploadHeap);
	m_curOffset = m_endOffset = 0U;
}

void * RingBuffer::subAllocate(uint32_t frameIdx, size_t size, size_t align)
{
	uint64_t alignMask = align - 1;
	size_t sizeAligned = (size + alignMask) & ~alignMask;

	if (m_size < sizeAligned)
	{
		return nullptr;
	}

	if (sizeAligned < getFreeSize())
	{
		size_t offsetAligned = (m_curOffset + alignMask) & ~alignMask;
		m_curOffset = (m_curOffset + sizeAligned) % m_size;
		m_endOffset = (m_endOffset + sizeAligned) % m_size;
		recordAllocInfo(frameIdx, size, offsetAligned);
		return (byte*)((size_t)(m_data + offsetAligned) % m_size);
	}
	else
	{
		freeMemory_waitGPU(frameIdx, sizeAligned);
		subAllocate(frameIdx, size, align);
	}
}

size_t RingBuffer::getFreeSize()
{
	if (m_curOffset < m_endOffset) 
	{
		return m_endOffset - m_curOffset;
	}
	return m_size - m_curOffset + m_endOffset;
}

void RingBuffer::freeMemory_waitGPU(uint32_t frameIdx, size_t sizeAlign)
{
	uint64_t lastCompleted = Graphics::g_CommandManager.GetGraphicsQueue().GetLastCompletedFenceValue();
	while (m_metaData.size() > 0 && m_metaData.front().frameIdx < lastCompleted)
	{
		m_metaData.pop_front();
	}
	if (m_metaData.size() > 0)
	{
		m_endOffset = m_metaData.front().offset;
		if (getFreeSize() < sizeAlign)
		{
			Graphics::g_CommandManager.GetGraphicsQueue().WaitForFence(frameIdx - 2);//double buffering
			freeMemory_waitGPU(frameIdx, sizeAlign);
		}
	}
	else
	{
		m_curOffset = m_endOffset = 0U;
	}
}

void RingBuffer::recordAllocInfo(uint32_t frameIdx, size_t size, size_t offset)
{
	AllocInfo info{};
	info.offset = offset;
	info.size = size;
	info.frameIdx = frameIdx;
	m_metaData.push_back(info);
}
