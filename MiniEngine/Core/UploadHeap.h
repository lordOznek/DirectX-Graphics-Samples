#pragma once
#include <queue>

struct RingBuffer
{
	struct AllocInfo
	{
		size_t offset;
		size_t size;
		uint32_t frameIdx;
	};

	// Allocates the backing buffer for the ring buffer
	void init(size_t size);
	// Sub-allocates in the ring buffer
	void * subAllocate(uint32_t frameIdx, size_t size, size_t align);
	// Return the free memory
	size_t getFreeSize();
	// Free memory by overiding sub-allocation from the processed frames
	// Note: can wait on the GPU to process frames
	void freeMemory_waitGPU(uint32_t frameIdx, size_t sizeAlign);
	// Push back the alloc info to the dequeue
	void recordAllocInfo(uint32_t frameIdx, size_t size, size_t align);

	byte * m_data;
	size_t m_curOffset;
	size_t m_endOffset;
	size_t m_size;
	ID3D12Heap * m_uploadHeap;
	std::deque<AllocInfo> m_metaData;
};

class UploadHeap
{
public:
	UploadHeap(size_t bufferSize);
	~UploadHeap();
	D3D12_CPU_DESCRIPTOR_HANDLE allocate(size_t size, size_t align);

private:
	RingBuffer m_uploadBuffer;
};

