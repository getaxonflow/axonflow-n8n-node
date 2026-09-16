# wait-for-approval-creates-queue-row

Drives the Wait for Approval operation through n8n's workflow runtime and
asserts, per edition, what the operation does. The edition is read from the
agent's `/health`; an edition the leg cannot read fails the leg.

- **Community.** `/api/v1/hitl/queue` is Enterprise-only and answers 404. The
  execution must end in error, and the node's error must name the edition:
  `AxonFlow has no approval queue at this endpoint (HTTP 404): /api/v1/hitl/queue is served by AxonFlow Enterprise only, ...`.
- **Enterprise.** The execution must succeed with an item carrying an
  `approval_id`, and `hitl_approval_queue` must hold exactly that row.

Wait for Approval creates the request and returns at once; it does not pause a
workflow. An n8n Wait node does that, so this leg does not assert a pause.

Before v11.1.0 this leg was named `wait-for-approval-pauses-workflow` and
passed on both a success and an error, so it asserted nothing about either.
