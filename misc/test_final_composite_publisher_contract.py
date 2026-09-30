"""Source-level lifetime and wakeup contracts for final-composite transport."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "libmachook/MacWSFinalCompositePublisher.m").read_text()


class FinalCompositePublisherContract(unittest.TestCase):
    def test_ordinary_frames_use_ordered_completion_callbacks(self):
        ordinary = SOURCE.split(
            "MacWSFinalCompositeSnapshotSlot *slot = AcquireSnapshotSlot(", 2
        )[2]
        self.assertLess(ordinary.index("[copyCommand addCompletedHandler:"),
                        ordinary.index("[copyCommand commit]"))
        self.assertIn("dispatch_async(CompletionQueue()", ordinary)
        self.assertNotIn("usleep(", ordinary)

    def test_replay_does_not_retain_the_producer_command_graph(self):
        self.assertIn("static id<MTLCommandQueue> ReplayMetalCommandQueue;",
                      SOURCE)
        self.assertNotIn("static id<MTLCommandBuffer> ReplayCommand;", SOURCE)
        ordinary = SOURCE.split(
            "MacWSFinalCompositeSnapshotSlot *slot = AcquireSnapshotSlot(", 2
        )[2]
        self.assertIn(
            "RememberReplaySource(retainedCopy.commandQueue,\n"
            "                                         slot->texture,",
            ordinary,
        )
        self.assertNotIn("RetainObject(commandBuffer)", ordinary)
        self.assertNotIn("RetainObject(sourceTexture)", ordinary)

    def test_replay_waits_without_submillisecond_polling(self):
        replay_copy = SOURCE.split("static bool SnapshotAndPublish(", 2)[2]
        replay_copy = replay_copy.split(
            "static BOOL ReplayRequesterIsDisplayd", 1
        )[0]
        self.assertIn("[copyCommand waitUntilCompleted]", replay_copy)
        self.assertNotIn("usleep(", replay_copy)

    def test_replay_cannot_blit_a_pool_texture_onto_itself(self):
        acquire = SOURCE.split(
            "static MacWSFinalCompositeSnapshotSlot *AcquireSnapshotSlot(", 1
        )[1].split("static void ReleaseSnapshotSlot", 1)[0]
        self.assertIn("id<MTLTexture> excludedTexture", acquire)
        self.assertIn("slot->texture == excludedTexture", acquire)
        self.assertIn("slot->reserved", acquire)


if __name__ == "__main__":
    unittest.main()
