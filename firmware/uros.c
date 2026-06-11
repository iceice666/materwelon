// micro-ROS integration for materwelon — RP2350 / Pico 2.
//
// Architecture:
//   • Transport : pico_uart_transport (routes through stdio; USB CDC when
//                 pico_enable_stdio_usb is set, UART0 otherwise).
//   • Node      : "materwelon" in the default namespace.
//   • Sub       : /servo_trajectory  (trajectory_msgs/msg/JointTrajectory)
//   • Callback  : traj_cb extracts positions[0..n-1] from the first trajectory
//                 point and calls the Zig-exported uros_dispatch(positions, n).
//
// Usage from the materwelon REPL:
//   (def handle-traj (fn [positions] (map servo-move positions)))
//   (uros-on-traj handle-traj)
//   uros start
//
// uros_init() + uros_spin_forever() are called by the "uros start" bare
// command in src/platform/rp2350.zig.  uros_spin_forever never returns;
// the only exit is a watchdog reboot.
//
// Memory: rcl uses newlib malloc (rcl_get_default_allocator), entirely
// separate from the Zig arenas.  The trajectory message is pre-sized for
// SERVO_COUNT joints so no heap allocation occurs on every received message.

#include <rcl/rcl.h>
#include <rcl/error_handling.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <trajectory_msgs/msg/joint_trajectory.h>
#include <rmw_microros/rmw_microros.h>

// pico_uart_transport.h is provided by the micro_ros_raspberrypi_pico_sdk
// inside the libmicroros include directory.
#include "pico_uart_transport.h"

// Maximum joints handled per trajectory point.  Matches the demo robot.
#define SERVO_COUNT 18

// ── Zig-exported entry point ──────────────────────────────────────────────────
// Defined in src/platform/rp2350.zig.  Called once per trajectory message
// with the positions array and element count.
extern void uros_dispatch(const double *positions, size_t n);

// ── Static micro-ROS state ────────────────────────────────────────────────────
static rcl_allocator_t    allocator;
static rclc_support_t     support;
static rcl_node_t         node;
static rcl_subscription_t sub;
static rclc_executor_t    executor;

// Pre-allocated message storage — avoids heap churn on every received message.
// traj_msg.points wraps a single point; point.positions wraps positions_data.
static double                                      positions_data[SERVO_COUNT];
static trajectory_msgs__msg__JointTrajectoryPoint  point;
static trajectory_msgs__msg__JointTrajectory       traj_msg;

// ── Subscription callback ─────────────────────────────────────────────────────

static void traj_cb(const void *msgin)
{
    const trajectory_msgs__msg__JointTrajectory *msg =
        (const trajectory_msgs__msg__JointTrajectory *)msgin;

    if (msg->points.size == 0) return;

    // Use the first trajectory point only.
    const trajectory_msgs__msg__JointTrajectoryPoint *pt = &msg->points.data[0];
    size_t n = pt->positions.size < SERVO_COUNT ? pt->positions.size : SERVO_COUNT;

    uros_dispatch(pt->positions.data, n);
}

// ── Initialisation ────────────────────────────────────────────────────────────

void uros_init(void)
{
    // Route micro-ROS traffic through pico stdio (USB CDC when
    // pico_enable_stdio_usb is set in CMakeLists.txt).
    rmw_uros_set_custom_transport(
        true,
        NULL,
        pico_uart_transport_open,
        pico_uart_transport_close,
        pico_uart_transport_write,
        pico_uart_transport_read
    );

    allocator = rcl_get_default_allocator();

    // Spin-wait for the micro-ROS agent to connect before continuing.
    // This blocks the REPL indefinitely until the agent is available.
    while (rmw_uros_ping_agent(200, 5) != RMW_RET_OK) {}

    rclc_support_init(&support, 0, NULL, &allocator);
    rclc_node_init_default(&node, "materwelon", "", &support);

    rclc_subscription_init_default(
        &sub, &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(trajectory_msgs, msg, JointTrajectory),
        "/servo_trajectory"
    );

    // Wire the pre-allocated buffers into the message struct so rclc never
    // calls malloc during deserialization.
    traj_msg.points.data     = &point;
    traj_msg.points.size     = 0;
    traj_msg.points.capacity = 1;

    point.positions.data     = positions_data;
    point.positions.size     = 0;
    point.positions.capacity = SERVO_COUNT;

    // velocities / accelerations / effort left at zero-capacity (not used).

    rclc_executor_init(&executor, &support.context, 1, &allocator);
    rclc_executor_add_subscription(&executor, &sub, &traj_msg, &traj_cb, ON_NEW_DATA);
}

// ── Blocking spin loop ────────────────────────────────────────────────────────

void uros_spin_forever(void)
{
    while (true) {
        rclc_executor_spin_some(&executor, RCL_MS_TO_NS(1));
    }
}
